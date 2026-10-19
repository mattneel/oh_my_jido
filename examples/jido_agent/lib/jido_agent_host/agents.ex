defmodule JidoAgentHost.ProjectStatus do
  use Jido.Action,
    name: "project_status",
    description: "Report the caller application's domain status",
    schema: Zoi.object(%{})

  @impl true
  def run(_params, _context) do
    {:ok,
     %{
       project_status: %{
         application: "jido_agent_host",
         version: to_string(Application.spec(:jido_agent_host, :vsn))
       }
     }}
  end
end

defmodule JidoAgentHost.Files do
  use Jido.Agent,
    name: "host_file_agent",
    default_plugins: false,
    plugins: [
      {OhMyJido.Plugin,
       %{bundles: [:read_only, :editing], context_provider: JidoAgentHost.Contexts}}
    ],
    schema: Zoi.object(%{project_label: Zoi.string() |> Zoi.default("independent-host")})

  def private_diagnostics?, do: true
end

defmodule JidoAgentHost.Editor do
  use Jido.AI.Agent,
    name: "host_editor_agent",
    model: "openai:gpt-4o-mini",
    tools: [JidoAgentHost.ProjectStatus],
    tool_max_retries: 0,
    max_iterations: 8,
    plugins: [
      {OhMyJido.Plugin,
       %{bundles: [:read_only, :editing], context_provider: JidoAgentHost.Contexts}}
    ]

  def private_diagnostics?, do: true
end
