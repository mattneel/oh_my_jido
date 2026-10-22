defmodule OhMyJido.MixProject do
  use Mix.Project

  @source_url "https://github.com/mattneel/oh_my_jido"

  def project do
    [
      app: :oh_my_jido,
      version: "0.1.0",
      name: "Oh-My-Jido",
      description: "An embeddable coding agent for Elixir applications, built on Jido.",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], optional: true, runtime: false}
    ]
  end

  defp docs do
    extras = [
      "README.md": [title: "Overview"],
      "docs/README.md": [filename: "documentation", title: "Documentation map"],
      "docs/getting-started.md": [],
      "docs/concepts.md": [],
      "docs/guides/running-tasks.md": [],
      "docs/guides/sessions-and-recovery.md": [],
      "docs/guides/tools.md": [],
      "docs/guides/permissions-and-approvals.md": [],
      "docs/guides/models-and-accounts.md": [],
      "docs/guides/subagents.md": [],
      "docs/guides/language-intelligence.md": [],
      "docs/guides/live-applications.md": [],
      "docs/guides/integrations.md": [],
      "docs/guides/eval.md": [],
      "docs/guides/jido-agents.md": [],
      "docs/guides/security.md": [],
      "docs/reference/api.md": [],
      "docs/reference/configuration.md": [],
      "docs/operations.md": [],
      "docs/project-status.md": [],
      "examples/plain_mix/README.md": [filename: "example-plain-mix"],
      "examples/jido_agent/README.md": [filename: "example-jido-agent"],
      "examples/docs_site/README.md": [filename: "example-docs-site"],
      "CHANGELOG.md": [],
      LICENSE: [title: "License"]
    ]

    [
      main: "readme",
      source_ref: "master",
      extras: extras,
      # Rewrites GitHub-relative links for ExDoc; loaded by the `docs` alias.
      markdown_processor:
        {OhMyJido.ExDocLinks, extras: extras, source_url: @source_url, source_ref: "master"},
      groups_for_extras: [
        Introduction: [
          "README.md",
          "docs/README.md",
          "docs/getting-started.md",
          "docs/concepts.md"
        ],
        Guides: ~r"docs/guides/",
        Reference: ~r"docs/reference/",
        Operations: ["docs/operations.md", "docs/project-status.md"],
        Examples: ~r"examples/"
      ],
      groups_for_modules: [
        "Runtime and sessions": [
          OhMyJido,
          OhMyJido.Runtime,
          OhMyJido.SessionRef,
          OhMyJido.Event,
          OhMyJido.Context,
          OhMyJido.Session,
          OhMyJido.ContextPolicy,
          OhMyJido.Prompt
        ],
        Tools: [OhMyJido.Tools, OhMyJido.Tool, ~r/^OhMyJido\.Tools\./],
        "Host policy, accounts and models": [
          OhMyJido.Host,
          ~r/^OhMyJido\.Host\./,
          OhMyJido.Auth,
          ~r/^OhMyJido\.Auth\./,
          OhMyJido.Models,
          ~r/^OhMyJido\.Models\./
        ],
        "Language intelligence and integrations": [
          ~r/^OhMyJido\.Intelligence\./,
          OhMyJido.Extensions,
          ~r/^OhMyJido\.Extensions\./
        ],
        Eval: [OhMyJido.Eval, ~r/^OhMyJido\.Eval\./],
        "Jido agent plugin": [OhMyJido.Plugin, ~r/^OhMyJido\.Plugin\./],
        "Files, processes and Git": [
          OhMyJido.Workspace,
          OhMyJido.Files,
          OhMyJido.Search,
          OhMyJido.Process,
          OhMyJido.Process.Handle,
          OhMyJido.Git,
          OhMyJido.Redact
        ],
        Installation: [OhMyJido.Install, Mix.Tasks.OhMyJido.Install]
      ]
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
      ],
      docs: [&load_docs_support/1, "docs"]
    ]
  end

  defp load_docs_support(_args) do
    Mix.Task.run("loadpaths")
    Code.require_file("docs/support/ex_doc_links.exs", __DIR__)
  end
end
