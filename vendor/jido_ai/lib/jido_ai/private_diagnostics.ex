# Added by Oh-My-Jido contributors, 2026-10-19: opt-in privacy for native V3
# Flow execution, request-owner callbacks, and OTP diagnostics. Success values
# remain native; Apache License 2.0, see LICENSE and UPSTREAM.json.
defmodule Jido.AI.PrivateDiagnostics do
  @moduledoc false
  alias Jido.AgentServer.PrivateDiagnostics, as: Core

  def enabled?(context) when is_map(context) do
    Core.active?() or context[:jido_ai_private_diagnostics] == true or
      Core.enabled?(context[:jido_ai_agent]) or Core.enabled?(context)
  end

  def enabled?(_), do: Core.active?()

  def exec_options(context, options \\ []) do
    if enabled?(context) do
      Keyword.put(options, :private_diagnostics, %{error: &Core.error/1, private?: true})
    else
      options
    end
  end

  def error(reason) do
    if Core.active?(), do: Core.error(reason), else: reason
  end

  def run(false, fun), do: fun.()

  def run(true, fun) do
    case Core.run(true, fun) do
      {:stop, reason} -> {:stop, Core.error(reason)}
      {:stop, reason, state} -> {:stop, Core.error(reason), state}
      {:stop, reason, reply, state} -> {:stop, Core.error(reason), reply, state}
      result -> result
    end
  end

  def format_status(%{state: state} = status) when is_map(state) do
    if state[:private_diagnostics?] == true or Core.active?() do
      summary = %{
        private_diagnostics?: true,
        pending_requests: map_size(Map.get(state, :jobs, %{}))
      }

      Map.new(status, fn
        {:state, _} -> {:state, summary}
        {:log, _} -> {:log, []}
        {:reason, _} -> {:reason, :private_ai_process_stopped}
        {key, _} -> {key, :private}
      end)
    else
      status
    end
  end

  def format_status(status), do: status
end
