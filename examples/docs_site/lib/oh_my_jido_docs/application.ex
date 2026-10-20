defmodule OhMyJidoDocs.Application do
  @moduledoc "One release with a small public renderer and an explicitly enabled trusted editor."
  use Application

  @impl true
  def start(_type, _args) do
    prepare_editor_storage()
    OhMyJidoDocs.Content.bootstrap!()

    children =
      [OhMyJidoDocsWeb.Telemetry, {Phoenix.PubSub, name: OhMyJidoDocs.PubSub}] ++
        editor_children() ++ [OhMyJidoDocsWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: OhMyJidoDocs.Supervisor)
  end

  defp editor_children do
    if Application.get_env(:oh_my_jido_docs, :editor_enabled, false) do
      database = [
        OhMyJidoDocs.Repo,
        {Ecto.Migrator,
         repos: [OhMyJidoDocs.Repo],
         skip: not Application.get_env(:oh_my_jido_docs, :migrate_on_start, false)}
      ]

      if Application.get_env(:oh_my_jido_docs, :start_private_workers, true),
        do: database ++ private_worker_specs(),
        else: database
    else
      []
    end
  end

  @doc false
  def private_worker_specs do
    if Application.get_env(:oh_my_jido_docs, :editor_enabled, false) do
      data = Application.fetch_env!(:oh_my_jido_docs, :data_dir)
      configure_toolchain()

      [
        {OhMyJido,
         name: OhMyJidoDocs.Coding,
         host: {OhMyJidoDocs.Editor.Host, []},
         storage: {Jido.Storage.File, path: Path.join(data, "sessions")},
         allow_test_scripts: Application.get_env(:oh_my_jido_docs, :allow_test_scripts, false),
         max_sessions: 8,
         max_active: 1,
         max_processes: 1,
         max_subagents: 1,
         max_resources: 8,
         max_runs: 64,
         max_effects: 256,
         event_limit: 256},
        {Task.Supervisor, name: OhMyJidoDocs.CandidateTasks, max_children: 1}
      ] ++ OhMyJidoDocs.Editor.child_specs() ++ OhMyJidoDocs.Candidates.child_specs()
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    OhMyJidoDocsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp prepare_editor_storage do
    if Application.get_env(:oh_my_jido_docs, :editor_enabled, false) do
      data = Application.fetch_env!(:oh_my_jido_docs, :data_dir)
      source = Application.fetch_env!(:oh_my_jido_docs, :source_root)

      if Path.dirname(data) == data or source == data or String.starts_with?(source, data <> "/"),
        do:
          raise(
            "Editor data must not be the filesystem root or contain the configured source seed"
          )

      File.mkdir_p!(data)
      File.chmod!(data, 0o700)
    end
  end

  defp configure_toolchain do
    configured = Application.get_env(:oh_my_jido_docs, :candidate_asset_tools, [])

    tools = [
      esbuild: Keyword.get(configured, :esbuild) || cached_binary(Esbuild, :bin_path, []),
      tailwind: Keyword.get(configured, :tailwind) || cached_binary(Tailwind, :bin_path, [])
    ]

    Application.put_env(:oh_my_jido_docs, :candidate_asset_tools, tools)
    environment = Application.get_env(:oh_my_jido_docs, :candidate_toolchain_env, %{})

    rebar =
      Map.get(environment, "MIX_REBAR3") || cached_binary(Mix.Rebar, :local_rebar_path, [:rebar3])

    if rebar,
      do:
        Application.put_env(
          :oh_my_jido_docs,
          :candidate_toolchain_env,
          Map.put(environment, "MIX_REBAR3", rebar)
        )
  end

  defp cached_binary(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)),
      do: apply(module, function, arguments)
  end
end
