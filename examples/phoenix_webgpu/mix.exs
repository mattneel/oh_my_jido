defmodule PhoenixWebGPU.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_webgpu,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_core_path: Path.join(["_build", Atom.to_string(Mix.env()), "dialyzer_core"])
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {PhoenixWebGPU.Application, []}]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  defp elixirc_paths(env) when env in [:test, :e2e], do: ["lib", "e2e/fixture"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    root = Path.expand("../..", __DIR__)

    [
      {:igniter, "~> 0.8", only: [:dev, :test], runtime: false},
      {:web_llm, path: Path.join(root, "packages/web_llm")},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:oh_my_jido, [path: root]},
      {:jido, [path: Path.join(root, "vendor/jido"), override: true]},
      {:req_llm, [path: Path.join(root, "vendor/req_llm"), override: true]},
      {:jido_ai, "== 2.4.0"},
      {:jido_action, "== 2.4.0"}
    ]
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
