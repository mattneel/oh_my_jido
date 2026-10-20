defmodule ElixosHost.Supervisor do
  @moduledoc "A host child specification; it never starts or replaces Elixos' services."
  use Supervisor

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    # LLMDB prepares its local catalog lazily; keep that work out of agent startup.
    LLMDB.providers()

    runtime = Keyword.get(options, :runtime, ElixosHost.Coding)
    approval_tasks = Keyword.get(options, :approval_tasks, ElixosHost.ApprovalTasks)

    storage_path =
      Keyword.get_lazy(options, :storage_path, fn ->
        Path.join(Application.get_env(:elixos, :priv_dir, "/priv"), "oh_my_jido/sessions")
      end)

    host_options =
      options
      |> Keyword.take([
        :credentials,
        :approval_timeout_ms,
        :helpers,
        :deployment_enabled,
        :build_options,
        :parent_generation,
        :network_boundary,
        :browser_exclusive
      ])
      |> Keyword.put(:approval_tasks, approval_tasks)

    browser_enabled = Keyword.get(options, :browser_enabled, false)
    browser_lease = Keyword.get(options, :browser_lease, ElixosHost.BrowserLease)
    browser_tasks = Keyword.get(options, :browser_tasks, ElixosHost.BrowserTasks)

    host_options =
      if browser_enabled,
        do: Keyword.put(host_options, :browser_lease, browser_lease),
        else: host_options

    browser_children =
      if browser_enabled do
        [
          {Task.Supervisor, name: browser_tasks, max_children: 1},
          {ElixosHost.BrowserLease, name: browser_lease, task_supervisor: browser_tasks}
        ]
      else
        []
      end

    runtime_options =
      options
      |> Keyword.take([
        :allow_test_scripts,
        :max_sessions,
        :max_active,
        :max_processes,
        :tool_timeout_ms,
        :run_timeout_ms
      ])

    runtime_options =
      Keyword.merge(runtime_options,
        name: runtime,
        storage: {Jido.Persistence.File, path: storage_path},
        host: {ElixosHost.Host, host_options},
        adapters:
          if(browser_enabled, do: %{browser: {ElixosHost.Browser, host_options}}, else: %{})
      )

    children =
      [{Task.Supervisor, name: approval_tasks}] ++
        browser_children ++ [{OhMyJido.Runtime, runtime_options}]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
