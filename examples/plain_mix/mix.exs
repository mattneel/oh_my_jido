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
      Enum.map([:jido, :jido_ai, :jido_action, :req_llm], fn app ->
        {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
      end)

    [
      {:oh_my_jido, path: root},
      {:jido_signal,
       git: "https://github.com/agentjido/jido_signal.git",
       ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
       override: true},
      {:zoi,
       git: "https://github.com/mikehostetler/zoi.git",
       ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
       override: true}
    ] ++ overrides
  end
end
