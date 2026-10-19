defmodule OhMyJido.Intelligence.DAP do
  @moduledoc """
  Reference stdio Debug Adapter Protocol client with explicit ownership.

  The host supplies the debugger executable, launch defaults and session context.
  Reverse process launches are denied. Launch is asynchronous because real
  adapters may defer its response until configurationDone; `await_launch` reports
  its actual outcome. Closing also terminates the owned adapter process group.
  """

  alias OhMyJido.Intelligence.Stdio
  alias OhMyJido.{Tool, Workspace}

  @pending_launch_receipt %{request_id: 1, status: :pending}
  @pending_launch_receipt_overhead byte_size(Jason.encode!(@pending_launch_receipt)) - 1

  @doc false
  @spec pending_launch_receipt(pos_integer()) :: map()
  def pending_launch_receipt(id), do: %{@pending_launch_receipt | request_id: id}

  @doc false
  @spec launch_receipt_budget(map()) :: {:ok, pos_integer()} | {:error, term()}
  def launch_receipt_budget(context) do
    maximum = Map.get(context.limits, :extension_result_bytes, 65_536)

    if is_integer(maximum) and maximum > @pending_launch_receipt_overhead,
      do: {:ok, maximum - @pending_launch_receipt_overhead},
      else: {:error, {:extension_result_limit, :debug, maximum}}
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 15_000
    }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Stdio.start_link(Keyword.put(opts, :protocol, :dap))

  @spec invoke(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(context, request, opts) do
    with server when not is_nil(server) <- Keyword.get(opts, :server),
         {:ok, identity} <- Stdio.bind(server, context) do
      execute(context, server, identity, request, opts)
    else
      nil -> {:error, {:capability_unavailable, :debug}}
      {:error, _} = error -> error
    end
  end

  @spec close_session(map(), keyword()) :: :ok | {:error, term()}
  defdelegate close_session(context, opts), to: Stdio

  defp execute(_context, server, identity, %{operation: :initialize}, opts) do
    args = %{
      "clientID" => "oh_my_jido",
      "clientName" => "Oh-My-Jido",
      "adapterID" => Keyword.get(opts, :adapter_id, "host"),
      "pathFormat" => "path",
      "linesStartAt1" => true,
      "columnsStartAt1" => true,
      "supportsVariableType" => true,
      "supportsRunInTerminalRequest" => false,
      "supportsStartDebuggingRequest" => false
    }

    request(server, identity, "initialize", args)
  end

  defp execute(context, server, identity, %{operation: :launch, program: program} = request, opts) do
    with {:ok, max_id_bytes} <- launch_receipt_budget(context),
         {:ok, absolute} <- Workspace.resolve(context, program),
         {:ok, cwd} <- Workspace.resolve(context, Map.get(request, :cwd, ".")) do
      args =
        Keyword.get(opts, :launch, %{})
        |> Map.merge(%{
          "program" => absolute,
          "cwd" => cwd,
          "args" => Map.get(request, :args, []),
          "console" => "internalConsole"
        })

      with {:ok, id} <-
             Stdio.begin_request(
               server,
               "launch",
               args,
               Keyword.get(opts, :pending_timeout_ms, 300_000),
               max_id_bytes
             ) do
        {:ok, Map.put(pending_launch_receipt(id), :identity, identity)}
      end
    end
  end

  defp execute(_context, server, identity, %{operation: :await_launch, request_id: id}, _opts) do
    case Stdio.await_response(server, id) do
      {:ok, result} ->
        {:ok, %{result: result, identity: identity}}

      {:error, reason} ->
        {:error, %{reason: :debug_launch_outcome_unknown, cause: reason, effect: :uncertain}}
    end
  end

  defp execute(_context, server, identity, %{operation: operation}, _opts)
       when operation in [:wait_initialized, :wait_stopped] do
    event = if operation == :wait_initialized, do: "initialized", else: "stopped"

    with {:ok, message} <- Stdio.await_event(server, event) do
      {:ok, %{event: message, identity: identity, trusted: false}}
    end
  end

  defp execute(
         context,
         server,
         identity,
         %{operation: :breakpoints, path: path, lines: lines},
         _opts
       ) do
    with {:ok, absolute} <- Workspace.resolve(context, path) do
      request(server, identity, "setBreakpoints", %{
        "source" => %{"path" => absolute},
        "breakpoints" => Enum.map(lines, &%{"line" => &1}),
        "sourceModified" => false
      })
    end
  end

  defp execute(_context, server, identity, %{operation: :configuration_done}, _opts),
    do: request(server, identity, "configurationDone", %{})

  defp execute(_context, server, identity, %{operation: :threads}, _opts),
    do: request(server, identity, "threads", %{})

  defp execute(
         _context,
         server,
         identity,
         %{operation: :stack_trace, thread_id: id} = input,
         _opts
       ),
       do:
         request(server, identity, "stackTrace", %{
           "threadId" => id,
           "startFrame" => Map.get(input, :start_frame, 0),
           "levels" => Map.get(input, :levels, 20)
         })

  defp execute(_context, server, identity, %{operation: :scopes, frame_id: id}, _opts),
    do: request(server, identity, "scopes", %{"frameId" => id})

  defp execute(
         _context,
         server,
         identity,
         %{operation: :variables, variables_reference: reference} = input,
         _opts
       ),
       do:
         request(server, identity, "variables", %{
           "variablesReference" => reference,
           "start" => Map.get(input, :start, 0),
           "count" => Map.get(input, :count, 100)
         })

  defp execute(_context, server, identity, %{operation: operation, thread_id: id}, _opts)
       when operation in [:step_over, :step_in, :step_out, :continue, :pause] do
    command =
      case operation do
        :step_over -> "next"
        :step_in -> "stepIn"
        :step_out -> "stepOut"
        :continue -> "continue"
        :pause -> "pause"
      end

    request(server, identity, command, %{"threadId" => id})
  end

  defp execute(context, server, identity, %{operation: :terminate}, _opts) do
    terminated = Stdio.request(server, "terminate", %{"restart" => false})

    disconnected =
      Stdio.request(server, "disconnect", %{"restart" => false, "terminateDebuggee" => true})

    target =
      if match?({:ok, _}, terminated) or match?({:ok, _}, disconnected),
        do: :acknowledged,
        else: :unconfirmed

    case Stdio.close(server, context) do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           terminate: outcome(terminated),
           disconnect: outcome(disconnected),
           debuggee_termination: target,
           cleanup_scope: :adapter_process_group
         })}

      {:error, :protocol_closed} ->
        {:ok,
         %{
           closed: true,
           cleanup: :owner_cleanup,
           identity: identity,
           terminate: outcome(terminated),
           disconnect: outcome(disconnected),
           debuggee_termination: target,
           cleanup_scope: :adapter_process_group
         }}

      {:error, _} = error ->
        error
    end
  end

  defp execute(_context, _server, _identity, _request, _opts),
    do: {:error, :unsupported_debug_operation}

  defp request(server, identity, command, args) do
    case Stdio.request(server, command, args) do
      {:ok, result} ->
        {:ok, %{result: result, identity: identity, trusted: false}}

      {:error, reason}
      when command in [
             "setBreakpoints",
             "configurationDone",
             "next",
             "stepIn",
             "stepOut",
             "continue",
             "pause"
           ] ->
        {:error,
         %{
           reason: :debug_operation_outcome_unknown,
           command: command,
           cause: reason,
           effect: :uncertain
         }}

      {:error, _} = error ->
        error
    end
  end

  defp outcome({:ok, result}), do: %{status: :ok, result: result}
  defp outcome({:error, reason}), do: %{status: :error, reason: inspect(reason)}

  @doc "Runs real breakpoint/step/variable operations against a human-supplied debugger."
  @spec smoke(map(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def smoke(context, server_opts, plan) do
    with :ok <-
           Tool.authorize(context, :debug, %{
             operation: :real_server_smoke,
             sensitive: true,
             executable: server_opts[:executable]
           }),
         {:ok, server} <-
           Stdio.start(
             Keyword.merge(server_opts, context: context, owner: self(), protocol: :dap)
           ) do
      opts = Keyword.put(server_opts, :server, server)

      try do
        with {:ok, initialized} <- invoke(context, %{operation: :initialize}, opts),
             {:ok, %{request_id: launch_id}} <-
               invoke(
                 context,
                 %{operation: :launch, program: plan.program, args: Map.get(plan, :args, [])},
                 opts
               ),
             {:ok, _} <- invoke(context, %{operation: :wait_initialized}, opts),
             {:ok, breakpoints} <-
               invoke(
                 context,
                 %{operation: :breakpoints, path: plan.source, lines: [plan.line]},
                 opts
               ),
             :ok <- verified_breakpoint(breakpoints),
             {:ok, _} <- invoke(context, %{operation: :configuration_done}, opts),
             {:ok, launched} <-
               invoke(context, %{operation: :await_launch, request_id: launch_id}, opts),
             {:ok, %{event: %{"body" => %{"threadId" => thread}}}} <-
               invoke(context, %{operation: :wait_stopped}, opts),
             {:ok, before} <- local_variable(context, opts, thread, plan.variable),
             {:ok, _} <- invoke(context, %{operation: :step_over, thread_id: thread}, opts),
             {:ok, _} <- invoke(context, %{operation: :wait_stopped}, opts),
             {:ok, after_value} <- local_variable(context, opts, thread, plan.variable),
             true <- before != after_value do
          {:ok,
           %{
             initialized: initialized,
             launched: launched,
             breakpoints: breakpoints,
             variable: plan.variable,
             before: before,
             after: after_value
           }}
        else
          false -> {:error, :dap_smoke_no_state_change}
          {:error, _} = error -> error
          _ -> {:error, :dap_smoke_evidence_unavailable}
        end
      after
        invoke(context, %{operation: :terminate}, opts)
        close_session(context, opts)
      end
    end
  end

  defp verified_breakpoint(%{result: %{"breakpoints" => breakpoints}}) do
    if Enum.any?(breakpoints, &(&1["verified"] == true)),
      do: :ok,
      else: {:error, :dap_breakpoint_unverified}
  end

  defp verified_breakpoint(_), do: {:error, :dap_breakpoint_unverified}

  defp local_variable(context, opts, thread, name) do
    with {:ok, %{result: %{"stackFrames" => [frame | _]}}} <-
           invoke(context, %{operation: :stack_trace, thread_id: thread}, opts),
         {:ok, %{result: %{"scopes" => scopes}}} <-
           invoke(context, %{operation: :scopes, frame_id: frame["id"]}, opts) do
      Enum.reduce_while(scopes, {:error, :dap_variable_not_found}, fn scope, _acc ->
        scope_variable(context, opts, scope, name)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :dap_frame_unavailable}
    end
  end

  defp scope_variable(context, opts, scope, name) do
    case invoke(
           context,
           %{operation: :variables, variables_reference: scope["variablesReference"]},
           opts
         ) do
      {:ok, %{result: %{"variables" => variables}}} ->
        case Enum.find(variables, &(&1["name"] == name)) do
          nil -> {:cont, {:error, :dap_variable_not_found}}
          variable -> {:halt, {:ok, variable["value"]}}
        end

      {:error, _} = error ->
        {:halt, error}
    end
  end
end
