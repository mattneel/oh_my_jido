defmodule OhMyJido.Tools.Debug do
  @moduledoc "Permission-checked debugger workflows through an explicitly bound adapter."

  use Jido.Action,
    name: "debug",
    description:
      "Use a host-bound debugger for breakpoints, stepping and variables. Launch returns a pending request_id; configure then await_launch before claiming startup. Terminate releases owned resources.",
    schema:
      Zoi.object(
        %{
          operation:
            Zoi.enum([
              "initialize",
              "launch",
              "await_launch",
              "wait_initialized",
              "breakpoints",
              "configuration_done",
              "threads",
              "wait_stopped",
              "stack_trace",
              "scopes",
              "variables",
              "step_over",
              "step_in",
              "step_out",
              "continue",
              "pause",
              "terminate"
            ]),
          program: Zoi.string() |> Zoi.optional(),
          path: Zoi.string() |> Zoi.optional(),
          cwd: Zoi.string() |> Zoi.default("."),
          args: Zoi.list(Zoi.string()) |> Zoi.default([]),
          lines: Zoi.list(Zoi.integer() |> Zoi.min(1)) |> Zoi.default([]),
          request_id: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
          thread_id: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
          frame_id: Zoi.integer() |> Zoi.min(0) |> Zoi.optional(),
          variables_reference: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
          start_frame: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
          levels: Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.default(20),
          start: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
          count: Zoi.integer() |> Zoi.min(1) |> Zoi.max(1_000) |> Zoi.default(100)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Host, Tool, Workspace}
  alias OhMyJido.Intelligence.DAP

  @operations Map.new(
                ~w(initialize launch await_launch wait_initialized breakpoints configuration_done threads wait_stopped stack_trace scopes variables step_over step_in step_out continue pause terminate)a,
                &{Atom.to_string(&1), &1}
              )
  @doc false
  def capability, do: :debug

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, params} <- Jido.Action.Schema.validate(schema(), params),
         {:ok, context} <- Context.fetch(execution_context),
         effect = %{
           operation: params.operation,
           program: Map.get(params, :program),
           path: Map.get(params, :path),
           sensitive: params.operation == "launch"
         },
         :ok <- Tool.authorize(context, :debug, effect),
         {:ok, operation} <- operation(Map.get(params, :operation)),
         {:ok, request} <- request(context, operation, params),
         :ok <- launch_budget(context, operation),
         {:ok, result} <- Host.call(context, :invoke, [:debug, request]) do
      bounded(context, operation, result)
    end
  end

  defp operation(value) do
    case Map.fetch(@operations, value) do
      :error -> {:error, :unsupported_debug_operation}
      {:ok, operation} -> {:ok, operation}
    end
  end

  defp request(context, :launch, params) do
    with program when is_binary(program) <- Map.get(params, :program),
         {:ok, absolute} <- Workspace.resolve(context, program),
         {:ok, cwd} <- Workspace.resolve(context, Map.get(params, :cwd, ".")),
         :ok <- args_valid(Map.get(params, :args, [])) do
      {:ok,
       %{
         operation: :launch,
         program: Workspace.relative(context, absolute),
         cwd: Workspace.relative(context, cwd),
         args: Map.get(params, :args, [])
       }}
    else
      nil -> {:error, :debug_program_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_debug_launch}
    end
  end

  defp request(context, :breakpoints, params) do
    with path when is_binary(path) <- Map.get(params, :path),
         {:ok, absolute} <- Workspace.resolve(context, path),
         lines when is_list(lines) <- Map.get(params, :lines, []),
         true <-
           Enum.count_until(lines, 1_001) <= 1_000 and
             Enum.all?(lines, &(is_integer(&1) and &1 > 0)) do
      {:ok, %{operation: :breakpoints, path: Workspace.relative(context, absolute), lines: lines}}
    else
      nil -> {:error, :debug_source_required}
      false -> {:error, :invalid_debug_breakpoints}
      {:error, _} = error -> error
      _ -> {:error, :invalid_debug_breakpoints}
    end
  end

  defp request(_context, operation, params) do
    required =
      case operation do
        :await_launch ->
          [:request_id]

        :scopes ->
          [:frame_id]

        :variables ->
          [:variables_reference]

        op when op in [:stack_trace, :step_over, :step_in, :step_out, :continue, :pause] ->
          [:thread_id]

        _ ->
          []
      end

    if Enum.all?(required, &(is_integer(Map.get(params, &1)) and Map.get(params, &1) >= 0)) do
      {:ok,
       params
       |> Map.take([
         :request_id,
         :thread_id,
         :frame_id,
         :variables_reference,
         :start_frame,
         :levels,
         :start,
         :count
       ])
       |> Map.put(:operation, operation)}
    else
      {:error, {:debug_field_required, required}}
    end
  end

  defp args_valid(args) do
    if is_list(args) and Enum.count_until(args, 101) <= 100 and
         Enum.all?(
           args,
           &(is_binary(&1) and byte_size(&1) <= 8_192 and not String.contains?(&1, <<0>>))
         ), do: :ok, else: {:error, :invalid_debug_arguments}
  end

  defp launch_budget(context, :launch) do
    with {:ok, _max_id_bytes} <- DAP.launch_receipt_budget(context), do: :ok
  end

  defp launch_budget(_context, _operation), do: :ok

  defp bounded(context, :launch, %{request_id: id, status: :pending} = result)
       when is_integer(id) and id > 0 do
    case bounded(context, result) do
      {:ok, _result} = bounded -> bounded
      {:error, _reason} -> bounded(context, DAP.pending_launch_receipt(id))
    end
  end

  defp bounded(context, _operation, result), do: bounded(context, result)

  defp bounded(context, result) do
    maximum = Map.get(context.limits, :extension_result_bytes, 65_536)

    case Jason.encode_to_iodata(result) do
      {:ok, encoded} ->
        if IO.iodata_length(encoded) <= maximum,
          do: {:ok, result},
          else: {:error, {:extension_result_limit, :debug, maximum}}

      {:error, _} ->
        {:error, :invalid_debug_result}
    end
  end
end
