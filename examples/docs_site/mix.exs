defmodule OhMyJidoDocs.MixProject do
  use Mix.Project

  def project do
    [
      app: :oh_my_jido_docs,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_core_path: Path.join(["_build", Atom.to_string(Mix.env()), "dialyzer_core"])
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {OhMyJidoDocs.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    root = Path.expand("../..", __DIR__)

    [
      {:oh_my_jido, path: root},
      {:jido, path: Path.join(root, "vendor/jido"), override: true},
      {:req_llm, path: Path.join(root, "vendor/req_llm"), override: true},
      {:jido_ai, path: Path.join(root, "vendor/jido_ai"), override: true},
      {:jido_action, path: Path.join(root, "vendor/jido_action"), override: true},
      {:jido_signal,
       git: "https://github.com/agentjido/jido_signal.git",
       ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
       override: true},
      {:zoi,
       git: "https://github.com/mikehostetler/zoi.git",
       ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
       override: true},
      {:mdex, "== 0.14.2"},
      {:pbkdf2_elixir, "~> 2.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.2", only: [:dev, :test], runtime: false},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind oh_my_jido_docs", "esbuild oh_my_jido_docs"],
      "assets.deploy": [
        "tailwind oh_my_jido_docs --minify",
        "esbuild oh_my_jido_docs --minify",
        "phx.digest"
      ],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ],
      precommit: ["ci"]
    ]
  end
end
