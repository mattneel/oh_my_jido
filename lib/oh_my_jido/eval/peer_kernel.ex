defmodule OhMyJido.Eval.PeerKernel do
  @moduledoc false
  use GenServer

  alias OhMyJido.Eval.{Output, PeerIO}

  @javascript_available Code.ensure_loaded?(QuickBEAM.Runtime)

  def start(language, opts) do
    GenServer.start(__MODULE__, {language, opts}, name: __MODULE__)
  end

  def execute(pid, request), do: GenServer.call(pid, {:execute, request}, :infinity)

  @impl true
  def init({language, opts}) do
    File.cd!(Keyword.fetch!(opts, :workspace))
    root = Process.group_leader()

    state = %{
      language: language,
      root: root,
      binding: [],
      env: Code.env_for_eval(file: "eval.exs"),
      runtime: nil
    }

    case language do
      :elixir ->
        ast = quote do: alias(OhMyJido.Eval.API, as: Eval)
        {_value, binding, env} = Code.eval_quoted_with_env(ast, [], state.env)
        {:ok, %{state | binding: binding, env: env}}

      :javascript ->
        init_javascript(opts, state)
    end
  end

  if @javascript_available do
    defp init_javascript(opts, state) do
      handlers =
        Map.new(QuickBEAM.Runtime.beam_handlers(), fn {name, _handler} ->
          {name, fn _args -> raise RuntimeError, "permission_denied: built-in Beam handler" end}
        end)

      handlers = Map.put(handlers, "omj_eval", &js_bridge/1)

      engine_opts =
        [
          memory_limit: 67_108_864,
          max_stack_size: 1_048_576,
          max_convert_depth: 16,
          max_convert_nodes: 4_096
        ]
        |> Keyword.merge(
          Keyword.take(opts, [
            :memory_limit,
            :max_stack_size,
            :max_convert_depth,
            :max_convert_nodes
          ])
        )

      with {:ok, runtime} <-
             QuickBEAM.start(Keyword.merge(engine_opts, apis: [], handlers: handlers)),
           {:ok, _value} <-
             QuickBEAM.eval(runtime, Keyword.fetch!(opts, :bootstrap), timeout: 5_000) do
        {:ok, %{state | runtime: runtime}}
      else
        {:error, reason} -> {:stop, {:javascript_unavailable, reason}}
      end
    end
  else
    defp init_javascript(_opts, _state),
      do: {:stop, {:javascript_unavailable, :dependency_not_available}}
  end

  @impl true
  def handle_call({:execute, request}, _from, state) do
    {:ok, io} = PeerIO.start_link(state.root, request)
    {:ok, stderr} = PeerIO.start_link(state.root, request, :stderr)
    old_stderr = Process.whereis(:standard_error)
    if old_stderr, do: Process.unregister(:standard_error)
    Process.register(stderr, :standard_error)
    old_leader = Process.group_leader()
    Process.group_leader(self(), io)
    :persistent_term.put({__MODULE__, :active}, %{io: io, request: request})

    try do
      {result, state} = evaluate(state.language, request, state)
      {:reply, {:ok, result}, state}
    after
      :persistent_term.erase({__MODULE__, :active})
      Process.group_leader(self(), old_leader)
      GenServer.stop(io, :normal)
      if Process.whereis(:standard_error) == stderr, do: Process.unregister(:standard_error)

      if old_stderr && Process.alive?(old_stderr),
        do: Process.register(old_stderr, :standard_error)

      GenServer.stop(stderr, :normal)
    end
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp evaluate(:elixir, request, state) do
    {outcome, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          quoted = Code.string_to_quoted!(request.source, file: "eval.exs", columns: true)
          {value, binding, env} = Code.eval_quoted_with_env(quoted, state.binding, state.env)
          {:ok, value, binding, env}
        rescue
          exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    case outcome do
      {:ok, value, binding, env} ->
        {display, clipped?} = Output.render_value(value, request.output_limit)
        result = %{status: :ok, display: display, diagnostics: diagnostics, truncated: clipped?}
        {result, %{state | binding: binding, env: env}}

      {:error, error} ->
        {error, clipped?} = Output.clip(error, request.output_limit)

        {%{
           status: :error,
           display: "",
           error: error,
           diagnostics: diagnostics,
           truncated: clipped?
         }, state}
    end
  end

  if @javascript_available do
    defp evaluate(:javascript, request, state) do
      cell = Jason.encode!(%{generation: request.generation, id: request.id})

      {:ok, _value} =
        QuickBEAM.eval(state.runtime, "globalThis.__omj_cell = Object.freeze(#{cell});",
          timeout: request.timeout
        )

      case QuickBEAM.eval(state.runtime, request.source, timeout: request.timeout) do
        {:ok, value} ->
          text =
            if is_binary(value),
              do: value,
              else: Output.inspect_value(value, request.output_limit)

          {text, clipped?} = Output.clip(text, request.output_limit)
          {%{status: :ok, display: text, diagnostics: [], truncated: clipped?}, state}

        {:error, reason} ->
          text =
            if is_binary(reason),
              do: reason,
              else: Output.inspect_value(reason, request.output_limit)

          status =
            if String.contains?(String.downcase(text), ["interrupted", "timeout", "timed out"]),
              do: :timeout,
              else: :error

          {text, clipped?} = Output.clip(text, request.output_limit)

          {%{status: status, display: "", error: text, diagnostics: [], truncated: clipped?},
           state}
      end
    end

    defp js_bridge([generation, id | args]) do
      case :persistent_term.get({__MODULE__, :active}, nil) do
        %{io: io, request: %{generation: ^generation, id: ^id}} ->
          operation =
            case args do
              ["tool", name, parameters] -> {:tool, name, parameters}
              ["display", value] -> {:display, value}
              ["artifact", name, media_type, data] -> {:artifact, name, media_type, data}
              ["output", "stdout", text] -> {:output, :stdout, text, false}
              ["output", "stderr", text] -> {:output, :stderr, text, false}
              _ -> :invalid
            end

          :io.request(io, {:omj_api, operation})

        _stale ->
          raise RuntimeError, "stale_execution"
      end
    end

    defp js_bridge(_args), do: raise(RuntimeError, "invalid_bridge_request")
  end
end
