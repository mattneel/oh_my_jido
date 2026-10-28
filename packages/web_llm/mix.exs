defmodule WebLLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :web_llm,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: "WebLLM (in-browser WebGPU inference) as a ReqLLM provider",
      package: [files: ~w(lib priv package.json mix.exs README.md)],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_core_path: Path.join(["_build", Atom.to_string(Mix.env()), "dialyzer_core"])
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {WebLLM.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    vendor = Path.expand("../../vendor", __DIR__)

    overrides =
      Enum.map([:req_llm], fn app ->
        {app, path: Path.join(vendor, Atom.to_string(app)), override: true}
      end)

    [
      {:jason, "~> 1.4"},
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:popcorn, "~> 1.0", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test},
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
        "cmd node --test 'test/js/*.test.mjs'",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
