defmodule OhMyJidoBrowser.Application do
  @moduledoc false

  use Application

  alias OhMyJidoBrowser.{Agent, Credentials, Workspace}

  @impl true
  def start(_type, _args) do
    children = if Popcorn.JS.available?(), do: browser_children(), else: []
    Supervisor.start_link(children, strategy: :rest_for_one, name: OhMyJidoBrowser.Supervisor)
  end

  # The agent starts only inside the browser VM. Natively (for example under
  # `mix test`) the application stays empty and never touches the host
  # filesystem.
  defp browser_children do
    :ok = Workspace.prepare!()

    [
      {Task.Supervisor, name: OhMyJidoBrowser.Tasks},
      Credentials,
      {OhMyJido, Agent.runtime_options()},
      OhMyJidoBrowser.UI
    ]
  end
end
