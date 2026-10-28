defmodule PhoenixWebGPU.SessionOwner do
  @moduledoc "Binds a server agent session and isolated temporary directories to one LiveView lifetime."
  use GenServer, restart: :temporary

  @doc "Starts a page-scoped agent owner under the demo's session supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the parent's public session reference."
  @spec session(pid()) :: OhMyJido.SessionRef.t()
  def session(owner), do: GenServer.call(owner, :session)

  @impl true
  def init(opts) do
    Process.monitor(Keyword.fetch!(opts, :live_view))
    root = Path.join(System.tmp_dir!(), "phoenix-webgpu-" <> Jido.Util.generate_id())
    parent_root = Path.join(root, "parent")
    child_root = Path.join(root, "browser")
    File.mkdir_p!(parent_root)
    File.mkdir_p!(child_root)

    metadata = %{
      browser_client: Keyword.fetch!(opts, :client),
      browser_role: Keyword.fetch!(opts, :role),
      browser_workspace: child_root,
      browser_observer: Keyword.fetch!(opts, :live_view),
      delegation_roots: [child_root]
    }

    session_opts = [
      workspace: parent_root,
      role: :coding,
      model: Application.fetch_env!(:phoenix_webgpu, :parent_model),
      account: "openrouter",
      permissions: [:delegate, :edit, :custom],
      metadata: metadata
    ]

    case OhMyJido.start_session(PhoenixWebGPU.Runtime, session_opts) do
      {:ok, session} ->
        {:ok, %{session: session, root: root}}

      {:error, reason} ->
        File.rm_rf(root)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:session, _from, state), do: {:reply, state.session, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    OhMyJido.stop_session(state.session)
    File.rm_rf(state.root)
    :ok
  end
end
