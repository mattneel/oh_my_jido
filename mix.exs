defmodule OhMyJido.MixProject do
  use Mix.Project

  def project do
    [
      app: :oh_my_jido,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps(),
      compilers:
        if(Mix.env() == :prod, do: Mix.compilers(), else: [:boundary] ++ Mix.compilers()),
      boundary: [default: [check: [apps: [{:mix, :runtime}]]]],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix, :quickbeam, :snakepit],
        plt_core_path: Path.join(["_build", Atom.to_string(Mix.env()), "dialyzer_core"])
      ],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {OhMyJido.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:boundary, "~> 0.11", runtime: false},
      {:glob_ex, "== 0.1.12"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.18"},
      {:req, "~> 0.7"},
      {:sourceror, "~> 1.12"},
      {:ex_ast, "~> 0.16"},
      {:req_llm, [path: "vendor/req_llm", override: true]},
      {:jido_action, "~> 2.4"},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:jido, [path: "vendor/jido", override: true]},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:snakepit, path: "vendor/snakepit", optional: true, runtime: false},
      {:quickbeam, "~> 0.11", optional: true, runtime: false},
      {:jido_ai, "~> 2.4"},
      {:igniter, "~> 0.6", only: [:dev, :test], optional: true, runtime: false}
    ]
  end

  defp aliases() do
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
