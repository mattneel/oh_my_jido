defmodule PlainMixHost.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    options = Application.get_env(:plain_mix_host, :coding, [])

    Supervisor.start_link([{PlainMixHost.Supervisor, options}],
      strategy: :one_for_one,
      name: PlainMixHost.ApplicationSupervisor
    )
  end
end

defmodule PlainMixHost.Supervisor do
  @moduledoc "The host, not the library application, chooses where Runtime is supervised."
  use Supervisor

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    runtime = Keyword.get(options, :runtime, PlainMixHost.Coding)
    storage = Keyword.get(options, :storage_path, Path.expand("var/sessions"))

    runtime_options =
      Keyword.take(options, [:allow_test_scripts, :max_sessions, :max_active, :credentials])

    children = [
      {OhMyJido,
       Keyword.merge(runtime_options,
         name: runtime,
         storage: {Jido.Storage.File, path: storage}
       )}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule PlainMixHost do
  @moduledoc "Embedded coding tasks, controls and durable identities through the public API."

  @tools OhMyJido.Tools.select!([:read_only, :editing, :process]) ++ [OhMyJido.Tools.Question]

  @doc "The caller supplies an explicit root; an opaque account can be supplied in options."
  def open(workspace, options \\ []) do
    {runtime, options} = Keyword.pop(options, :runtime, PlainMixHost.Coding)
    options = Keyword.put(options, :workspace, workspace)
    options = Keyword.put_new(options, :permissions, [:read, :edit, :exec, :ask])
    options = Keyword.put_new(options, :tools, @tools)
    OhMyJido.start_session(runtime, options)
  end

  def submit(session, requirement, options \\ []),
    do: OhMyJido.prompt(session, requirement, options)

  def restore(id, options \\ []) do
    OhMyJido.resume_session(Keyword.get(options, :runtime, PlainMixHost.Coding), id)
  end
end
