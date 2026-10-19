defmodule ElixosHostSource.MixProject do
  use Mix.Project

  @services ~w(agents session ask browser candidate health image privileges decimal package oban postgres boot)
  @directories ~w(candidate image browser shim privileges package oban)

  def source do
    Path.expand(System.get_env("ELIXOS_SOURCE") || "../../../../elixos/os", __DIR__)
  end

  def sources do
    root = Path.join(source(), "lib/elixos")

    files =
      Enum.map(@services, &Path.join(root, &1 <> ".ex")) ++
        Enum.flat_map(@directories, &Path.wildcard(Path.join([root, &1, "**/*.ex"]))) ++
        Enum.map(~w(env cmdline base), &Path.join([root, "boot", &1 <> ".ex"]))

    Enum.each(files, fn file ->
      unless File.regular?(file), do: Mix.raise("Missing actual Elixos service source: #{file}")
    end)

    Enum.sort(Enum.uniq(files))
  end

  def project do
    [
      app: :elixos,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: sources(),
      deps: deps()
    ]
  end

  # No Elixos.Application: tests start only selected real services. Candidate's
  # child suite still sees an actual :elixos app without booting guest services.
  def application, do: [extra_applications: [:logger, :crypto, :public_key]]

  defp deps do
    root = source()

    lock = Mix.Dep.Lock.read(Path.join(root, "mix.lock"))
    coding = Path.expand(System.get_env("ELIXOS_OH_MY_JIDO_SOURCE") || "../../..", __DIR__)

    native = [{:jido, path: Path.join(coding, "vendor/jido"), override: true}]

    selected =
      for app <- [:cdp_ex, :oban, :ecto_sql, :postgrex, :ecto, :decimal, :db_connection, :crontab] do
        {:hex, _package, version, _checksum, _managers, _deps, _repo, _outer} =
          Map.fetch!(lock, app)

        {app, "== #{version}", path: Path.join([root, "deps", Atom.to_string(app)])}
      end

    native ++ selected
  end
end
