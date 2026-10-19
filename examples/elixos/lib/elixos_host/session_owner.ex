defmodule ElixosHost.SessionOwner do
  @moduledoc "An ordinary Elixos.Agents child; snapshots retain identities, not BEAM handles."
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def session(pid), do: GenServer.call(pid, :session)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    runtime = Keyword.fetch!(options, :runtime)
    id = Keyword.fetch!(options, :id)

    case open_session(runtime, id, Keyword.get(options, :snapshot), options) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:session, _from, session), do: {:reply, session, session}

  def handle_call(:snapshot, _from, session) do
    {:reply, %{version: 1, session: %{runtime: session.runtime, id: session.id}}, session}
  end

  @impl true
  def terminate(_reason, session) do
    # The separately supervised Runtime may already have shut down its sessions.
    case OhMyJido.Runtime.config(session.runtime) do
      {:error, :runtime_unavailable} ->
        :ok

      {:ok, _config} ->
        :ok = OhMyJido.stop_session(session)
    end
  end

  defp open_session(runtime, id, nil, options) do
    case Enum.find(OhMyJido.list_sessions(runtime), &(&1.id == id)) do
      nil -> OhMyJido.start_session(runtime, Keyword.drop(options, [:runtime, :snapshot]))
      session -> ensure_workspace(session, Keyword.fetch!(options, :workspace))
    end
  end

  defp open_session(runtime, id, %{version: 1, session: %{runtime: runtime, id: id}}, options) do
    restored =
      case Enum.find(OhMyJido.list_sessions(runtime), &(&1.id == id)) do
        nil -> OhMyJido.resume_session(runtime, id)
        session -> {:ok, session}
      end

    with {:ok, session} <- restored,
         do: ensure_workspace(session, Keyword.fetch!(options, :workspace))
  end

  defp open_session(_runtime, _id, _snapshot, _options), do: {:error, :invalid_lifecycle_snapshot}

  defp ensure_workspace(session, expected) do
    case OhMyJido.inspect_session(session) do
      {:ok, %{workspace: ^expected}} -> {:ok, session}
      {:ok, _other} -> {:error, :session_workspace_mismatch}
      {:error, _reason} = error -> error
    end
  end
end
