defmodule ElixosHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixos_host,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps_path: System.get_env("ELIXOS_FACTORY_DEPS") || "deps",
      lockfile: if(factory?(), do: Path.join(source(), "mix.lock"), else: "mix.lock"),
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps()
    ]
  end

  # The Elixos host explicitly places ElixosHost.Supervisor in its tree.
  def application, do: [extra_applications: [:logger]]

  defp deps do
    root = Path.expand("../..", __DIR__)
    source = source()

    native_overrides =
      for app <- [:jido, :jido_ai, :jido_action, :req_llm] do
        {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
      end

    native_overrides =
      native_overrides ++
        [
          {:jido_signal,
           git: "https://github.com/agentjido/jido_signal.git",
           ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
           override: true},
          {:zoi,
           git: "https://github.com/mikehostetler/zoi.git",
           ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
           override: true}
        ]

    # These installer-less transitive BEAM packages already exist in Elixos'
    # lock/source. Keep their actual pins, not guessed cross-project constraints.
    if factory?() do
      # A normal Mix app against the complete OS. Shared target build/lock
      # avoids recompiling a second OS; host_source is exclusively a host test.
      [{:oh_my_jido, path: root}, {:elixos, path: source}] ++ native_overrides
    else
      lock = Mix.Dep.Lock.read(Path.join(source, "mix.lock"))

      source_overrides =
        Enum.map([:ecto, :ecto_sql, :postgrex, :decimal, :db_connection, :crontab], fn app ->
          {:hex, _package, version, _checksum, _managers, _deps, _repo, _outer} =
            Map.fetch!(lock, app)

          {app, "== #{version}",
           path: Path.join([source, "deps", Atom.to_string(app)]), override: true}
        end)

      [{:oh_my_jido, path: root}, {:elixos, path: "host_source"}] ++
        native_overrides ++ source_overrides
    end
  end

  defp factory?, do: System.get_env("ELIXOS_FACTORY") == "1"
  defp source, do: Path.expand(System.get_env("ELIXOS_SOURCE") || "../../../elixos/os", __DIR__)
end
