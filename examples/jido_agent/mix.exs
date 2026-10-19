defmodule JidoAgentHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_agent_host,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    root = Path.expand("../..", __DIR__)

    overrides =
      Enum.map([:jido, :req_llm], fn app ->
        {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
      end)

    [
      {:oh_my_jido, path: root},
      {:jido_ai, "== 2.4.0"},
      {:jido_action, "== 2.4.0"}
    ] ++ overrides
  end
end
