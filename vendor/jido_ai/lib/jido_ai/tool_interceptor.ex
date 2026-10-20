# Modified by Oh-My-Jido contributors, 2026-10-19: adapt optional native
# target Exec lifecycle receipts directly through declared interceptors.
# Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule Jido.AI.ToolInterceptor do
  @moduledoc """
  Optional AI-agent callbacks for canonical tool-call interception.

  Agent-managed AI Flows invoke these hooks around one logical tool execution.
  Modules that do not export a hook use identity behavior. A native AI profile
  can name a `tool_interceptor` module. Otherwise the host Agent's callbacks
  apply. Caller context cannot select the callback module.

  `before_tool_call/2` runs after the runtime resolves the action module and
  before argument validation, execution, and retries. It can change only the
  `:arguments` map. The tool call `:id`, `:name`, and `:action_module` are
  immutable. On v3, `:action_module` can also hold a declared Flow value.

  `after_tool_call/3` runs once after retries produce a final canonical result.
  It can change the result payload and effects. The runtime applies the active
  effect policy to the returned effects. ReAct collects the full model tool
  batch before result callbacks run in call order. Completed external work
  can therefore precede a later callback failure.

  The before/after hooks run in the strategy execution path. They must return
  quickly and must not depend on being called from the action process. A callback
  error, invalid return, exception, throw, or exit stops the current tool round
  with a structured interceptor error.

  `tool_execution_started/3` and `tool_execution_stopped/4` are an optional pair
  for native target Exec lifecycle receipts. They run directly in the actual
  Exec controller, not through another Exec. The full trusted native context is
  captured before tool context forwarding; model arguments and tool context
  cannot install or replace these callbacks. Nested native Exec calls inherit
  the observer and report the current opaque token in their proof's `:parent`.
  Receipts describe execution-group lifetime, not successful tool output.

  These hooks apply to agent-managed tool execution. Standalone direct calls
  through `Jido.AI.Model.Response`, `Jido.Exec`, or tool-calling actions do not
  install agent callbacks. Nested Exec calls retain any active lifecycle observer.
  """

  alias Jido.AI.Effects

  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => map(),
          required(:action_module) => module() | Jido.Flow.t()
        }

  @type tool_result :: {:ok, term(), [term()]} | {:error, term(), [term()]}

  @type lifecycle_proof :: %{
          required(:controller) => pid(),
          required(:supervisor) => pid(),
          required(:execution_id) => term(),
          required(:owner) => pid(),
          required(:parent) => term(),
          optional(:workers_stopped) => true
        }

  @doc """
  Transforms a resolved tool call before argument validation and execution.

  The callback can change only `tool_call.arguments`. Return `{:interrupt,
  value}` to stop the current tool round without executing the tool.
  """
  @callback before_tool_call(tool_call(), map()) ::
              {:ok, tool_call()} | {:error, term()} | {:interrupt, term()}

  @doc """
  Transforms the final canonical result after tool retries finish.

  Return the transformed result inside `{:ok, result}`. Return `{:error,
  reason}` to stop the current tool round because the interceptor failed.
  """
  @callback after_tool_call(tool_call(), tool_result(), map()) ::
              {:ok, tool_result()} | {:error, term()}

  @doc """
  Admits a native target or nested Exec after its private supervisor exists and
  before Action or Flow work is released.

  Return `{:ok, token}` to admit work, `{:halt, token, reason}` to reject work
  while retaining a token for its closed-group receipt, or `{:error, reason}` to
  fail closed. Invalid returns and escaping failures also reject execution.
  This callback is active only when both lifecycle callbacks are exported.
  """
  @callback tool_execution_started(tool_call(), lifecycle_proof(), map()) ::
              {:ok, term()} | {:halt, term(), term()} | {:error, term()}

  @doc """
  Receives the original opaque token only after native synchronous worker-group
  shutdown and waits succeed. The proof includes `workers_stopped: true`.

  A skipped or failed shutdown has no affirmative receipt. This callback cannot
  replace the real execution result. Return `:ok` or `{:error, reason}`.
  """
  @callback tool_execution_stopped(tool_call(), term(), lifecycle_proof(), map()) ::
              :ok | {:error, term()}

  @optional_callbacks before_tool_call: 2,
                      after_tool_call: 3,
                      tool_execution_started: 3,
                      tool_execution_stopped: 4

  @doc false
  @spec lifecycle_observer(module() | nil, tool_call(), map()) :: map() | nil
  def lifecycle_observer(agent_module, tool_call, context) do
    if exports_callback?(agent_module, :tool_execution_started, 3) and
         exports_callback?(agent_module, :tool_execution_stopped, 4) do
      private? = Jido.AI.PrivateDiagnostics.enabled?(context)

      %{
        started: fn proof ->
          invoke_lifecycle_callback(
            agent_module,
            :tool_execution_started,
            [tool_call, proof, context],
            private?
          )
        end,
        stopped: fn token, proof ->
          invoke_lifecycle_callback(
            agent_module,
            :tool_execution_stopped,
            [tool_call, token, proof, context],
            private?
          )
        end,
        parent: nil
      }
    end
  end

  @doc false
  @spec before_tool_call(module() | nil, map(), map()) ::
          {:ok, tool_call()} | {:error, term()} | {:interrupt, term()}
  def before_tool_call(agent_module, tool_call, context)
      when is_map(tool_call) and is_map(context) do
    with {:ok, original} <- normalize_tool_call(tool_call),
         {:ok, callback_result} <- invoke_before_callback(agent_module, original, context) do
      normalize_before_result(callback_result, original, agent_module)
    end
  end

  def before_tool_call(_agent_module, tool_call, _context) do
    {:error, {:invalid_tool_call, tool_call}}
  end

  @doc false
  @spec after_tool_call(module() | nil, tool_call(), term(), map()) ::
          {:ok, tool_result()} | {:error, term()}
  def after_tool_call(agent_module, tool_call, result, context)
      when is_map(tool_call) and is_map(context) do
    with {:ok, result, _stats} <-
           after_tool_call_with_stats(agent_module, tool_call, result, context),
         do: {:ok, result}
  end

  def after_tool_call(agent_module, tool_call, _result, _context) do
    {:error, {:invalid_tool_call, agent_module, tool_call}}
  end

  @doc false
  def after_tool_call_with_stats(agent_module, tool_call, result, context) do
    with {:ok, normalized_call} <- normalize_tool_call(tool_call),
         normalized_result <- Effects.normalize_result(result),
         {:ok, callback_result} <-
           invoke_after_callback(agent_module, normalized_call, normalized_result, context) do
      normalize_after_result(callback_result, agent_module, context)
    end
  end

  defp exports_callback?(module, name, arity) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, name, arity)
  end

  defp exports_callback?(_module, _name, _arity), do: false

  defp invoke_before_callback(agent_module, tool_call, context) do
    case exports_callback?(agent_module, :before_tool_call, 2) do
      true -> invoke_callback(agent_module, :before_tool_call, [tool_call, context])
      false -> {:ok, {:ok, tool_call}}
    end
  end

  defp invoke_after_callback(agent_module, tool_call, result, context) do
    case exports_callback?(agent_module, :after_tool_call, 3) do
      true -> invoke_callback(agent_module, :after_tool_call, [tool_call, result, context])
      false -> {:ok, {:ok, result}}
    end
  end

  defp invoke_lifecycle_callback(agent_module, callback, args, private?) do
    Jido.AI.PrivateDiagnostics.run(private?, fn ->
      Jido.AI.Error.capture(fn ->
        with {:ok, result} <- invoke_callback(agent_module, callback, args) do
          normalize_lifecycle_result(result, callback, agent_module)
        end
      end)
    end)
  end

  defp invoke_callback(agent_module, callback, args) do
    {:ok, apply(agent_module, callback, args)}
  rescue
    error -> {:error, callback_exception(callback, agent_module, error)}
  catch
    kind, reason -> {:error, callback_catch(callback, agent_module, kind, reason)}
  end

  defp normalize_before_result({:ok, %{} = tool_call}, original, agent_module) do
    with {:ok, normalized} <- normalize_tool_call(tool_call),
         :ok <- preserve_identity(original, normalized, agent_module) do
      {:ok, normalized}
    end
  end

  defp normalize_before_result({:error, reason}, _original, agent_module) do
    {:error, {:tool_interceptor, :before_tool_call, agent_module, reason}}
  end

  defp normalize_before_result({:interrupt, value}, _original, _agent_module),
    do: {:interrupt, value}

  defp normalize_before_result(other, _original, agent_module) do
    {:error, {:invalid_tool_interceptor_result, :before_tool_call, agent_module, other}}
  end

  defp normalize_after_result({:ok, result}, agent_module, context) do
    case canonical_tool_result(result) do
      {:ok, normalized_result} ->
        policy = Effects.policy_from_context(context, Effects.default_policy())
        {filtered_result, stats} = Effects.filter_result(normalized_result, policy)
        {:ok, filtered_result, stats}

      :error ->
        {:error,
         {:invalid_tool_interceptor_result, :after_tool_call, agent_module, {:ok, result}}}
    end
  end

  defp normalize_after_result({:error, reason}, agent_module, _context) do
    {:error, {:tool_interceptor, :after_tool_call, agent_module, reason}}
  end

  defp normalize_after_result(other, agent_module, _context) do
    {:error, {:invalid_tool_interceptor_result, :after_tool_call, agent_module, other}}
  end

  defp normalize_lifecycle_result({:ok, token}, :tool_execution_started, _agent_module),
    do: {:ok, token}

  defp normalize_lifecycle_result({:halt, token, reason}, :tool_execution_started, _agent_module),
    do: {:halt, token, Jido.AI.PrivateDiagnostics.error(reason)}

  defp normalize_lifecycle_result(:ok, :tool_execution_stopped, _agent_module), do: :ok

  defp normalize_lifecycle_result({:error, reason}, callback, agent_module),
    do: {:error, {:tool_interceptor, callback, agent_module, reason}}

  defp normalize_lifecycle_result(other, callback, agent_module),
    do: {:error, {:invalid_tool_interceptor_result, callback, agent_module, other}}

  defp canonical_tool_result({status, _payload, effects} = result)
       when status in [:ok, :error] and is_list(effects),
       do: {:ok, result}

  defp canonical_tool_result(_result), do: :error

  defp normalize_tool_call(%{} = tool_call) do
    id =
      Map.get(
        tool_call,
        :id,
        Map.get(tool_call, "id", Map.get(tool_call, :call_id, Map.get(tool_call, "call_id")))
      )

    name =
      Map.get(
        tool_call,
        :name,
        Map.get(
          tool_call,
          "name",
          Map.get(tool_call, :tool_name, Map.get(tool_call, "tool_name"))
        )
      )

    arguments = Map.get(tool_call, :arguments, Map.get(tool_call, "arguments", %{})) || %{}
    action_module = Map.get(tool_call, :action_module, Map.get(tool_call, "action_module"))

    cond do
      not is_binary(id) ->
        {:error, {:invalid_tool_call_id, id}}

      not is_binary(name) ->
        {:error, {:invalid_tool_call_name, name}}

      not is_map(arguments) ->
        {:error, {:invalid_tool_call_arguments, arguments}}

      not ((is_atom(action_module) and not is_nil(action_module)) or
               is_struct(action_module, Jido.Flow)) ->
        {:error, {:invalid_tool_call_action_module, action_module}}

      true ->
        {:ok, %{id: id, name: name, arguments: arguments, action_module: action_module}}
    end
  end

  defp preserve_identity(original, transformed, agent_module) do
    cond do
      transformed.id != original.id ->
        {:error, {:tool_interceptor_changed_id, agent_module, original.id, transformed.id}}

      transformed.name != original.name ->
        {:error, {:tool_interceptor_changed_name, agent_module, original.name, transformed.name}}

      transformed.action_module != original.action_module ->
        {:error,
         {:tool_interceptor_changed_action_module, agent_module, original.action_module,
          transformed.action_module}}

      true ->
        :ok
    end
  end

  defp callback_exception(callback, agent_module, error) do
    {:tool_interceptor_exception, callback, agent_module,
     %{type: error.__struct__, message: Exception.message(error)}}
  end

  defp callback_catch(callback, agent_module, kind, reason) do
    {:tool_interceptor_catch, callback, agent_module, %{kind: kind, reason: inspect(reason)}}
  end
end
