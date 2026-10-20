defmodule OhMyJidoDocs.Editor.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: OhMyJidoDocs.Editor.WriterRegistry},
      Supervisor.child_spec(
        {Task.Supervisor, name: OhMyJidoDocs.Editor.WriterTasks, max_children: 8},
        id: OhMyJidoDocs.Editor.WriterTasks
      ),
      Supervisor.child_spec({Task.Supervisor, name: OhMyJidoDocs.Editor.Tasks, max_children: 2},
        id: OhMyJidoDocs.Editor.Tasks
      ),
      Supervisor.child_spec({OhMyJidoDocs.Editor.Observer, []}, shutdown: 15_000)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
