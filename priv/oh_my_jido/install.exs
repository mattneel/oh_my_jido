# Run with elixir, from the consumer directory, before resolving its Mix graph.
# First use may fetch ordinary installer dependencies into Mix.install's cache.
# Consumer files are previewed only unless both --apply and --yes are supplied.
source = Path.expand("../..", __DIR__)

Mix.install(
  [{:igniter, "== 0.8.4"}],
  lockfile: Path.join(source, "mix.lock"),
  start_applications: false,
  consolidate_protocols: false
)

Code.require_file(Path.join(source, "lib/oh_my_jido/install.ex"))

case OhMyJido.Install.run(System.argv(), source) do
  {:ok, _result} ->
    :ok

  {:error, message} ->
    IO.puts(:stderr, message)
    System.halt(1)
end
