defmodule OhMyJidoBrowser.MixProject do
  use Mix.Project

  def project do
    [
      app: :oh_my_jido_browser,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_core_path: Path.join(["_build", Atom.to_string(Mix.env()), "dialyzer_core"])
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OhMyJidoBrowser.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(:e2e), do: ["lib", "e2e/fixture"]
  defp elixirc_paths(:test), do: ["lib", "support", "test/support"]
  defp elixirc_paths(_env), do: ["lib", "support"]

  defp deps do
    root = Path.expand("../..", __DIR__)

    overrides =
      Enum.map([:jido, :req_llm], fn app ->
        {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
      end)

    [
      {:oh_my_jido, path: root},
      {:web_llm, path: Path.join(root, "packages/web_llm")},
      {:popcorn, "1.0.0"},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false}
    ] ++ overrides
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
