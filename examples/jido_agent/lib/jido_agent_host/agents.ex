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
  use Jido.Agent, name: "host_file_agent"

  agent do
    schema(Zoi.object(%{project_label: Zoi.string() |> Zoi.default("independent-host")}))

    plugin(OhMyJido.Plugin,
      config: [bundles: [:read_only, :editing], context_provider: JidoAgentHost.Contexts]
    )
  end

  routes do
    route("oh_my_jido.read", OhMyJido.Plugin.Tools.Read)
    route("oh_my_jido.edit", OhMyJido.Plugin.Tools.Edit)
  end

  def private_diagnostics?, do: true
end

defmodule JidoAgentHost.Editor do
  use Jido.AI.Agent,
    name: "host_editor_agent",
    extensions: [OhMyJido.Plugin.AgentExtension]

  agent do
    schema(
      Zoi.object(%{
        answer: Zoi.string() |> Zoi.default(""),
        project_label: Zoi.string() |> Zoi.default("independent-host")
      })
    )

    plugin(OhMyJido.Plugin,
      config: [bundles: [:read_only, :editing], context_provider: JidoAgentHost.Contexts]
    )

    ai :assistant do
      model("openai:gpt-4o-mini")
      reasoning(:react)

      controls do
        max_iterations(8)
      end

      tools do
        action(JidoAgentHost.ProjectStatus)
      end

      observability do
        stream_content(true)
      end

      result(into: :answer)
    end
  end

  routes do
    route("editor.ask", ai: :assistant)
  end

  def private_diagnostics?, do: true
end
