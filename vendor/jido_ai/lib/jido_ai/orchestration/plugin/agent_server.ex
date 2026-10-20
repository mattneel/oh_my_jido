# Modified by Oh-My-Jido contributors, 2026-10-19: inherit the native Agent
# module's opt-in privacy scope when its Coordinator child is constructed.
# Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule Jido.AI.Orchestration.Plugin.AgentServer do
  @moduledoc false
  @behaviour Jido.Plugin

  alias Jido.AI.Orchestration.{Plugin, Coordinator}

  @impl Jido.Plugin
  def child_spec(init) do
    private? = Jido.AgentServer.PrivateDiagnostics.active?()
    Supervisor.child_spec({Coordinator, {init, private?}}, id: Plugin)
  end

  @impl Jido.Plugin
  def await_ready(runtime, _opts), do: GenServer.call(runtime, :ready)

  @impl Jido.Plugin
  def admit(runtime, admission, opts), do: Plugin.prepare_admission(runtime, admission, opts)

  @impl Jido.Plugin
  def dispatch(runtime, directive, context, _opts),
    do: Plugin.dispatch_directive(runtime, directive, context)
end
