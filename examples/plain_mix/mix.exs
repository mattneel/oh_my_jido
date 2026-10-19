defmodule PlainMixHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :plain_mix_host,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps_path: "deps",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {PlainMixHost.Application, []}]
  end

  defp deps do
    root = Path.expand("../..", __DIR__)

    overrides =
      Enum.map([:jido, :req_llm], fn app ->
        {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
      end)

    [{:oh_my_jido, path: root}] ++ overrides
  end
end
