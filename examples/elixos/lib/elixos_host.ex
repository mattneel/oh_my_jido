defmodule ElixosHost do
  @moduledoc "Elixos.Agents owns coding-session lifecycle; group leaders own caller roots."

  @session_options [:runtime, :id, :permissions, :account, :model, :role, :goal]

  @doc "Capture the requester directory before entering any supervisor or agent process."
  def open(options \\ []) do
    requester_root = Elixos.Session.cwd_for(Process.group_leader())
    id = Keyword.get_lazy(options, :id, &Jido.Util.generate_id/0)

    cond do
      not Keyword.keyword?(options) or
          Enum.any?(Keyword.keys(options), &(&1 not in @session_options)) ->
        {:error, :invalid_host_session_options}

      not is_binary(id) or not Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id) ->
        {:error, :invalid_host_session_id}

      true ->
        with {:ok, root} <- OhMyJido.Workspace.new(requester_root) do
          options =
            options
            |> Keyword.put(:workspace, root)
            |> Keyword.put(:id, id)
            |> Keyword.put_new(:runtime, ElixosHost.Coding)
            |> Keyword.put_new(:permissions, [:read, :edit, :ask])

          Elixos.Agents.start(ElixosHost.SessionOwner, options)
        end
    end
  end

  @doc "Resolve an Elixos owner to the library's durable SessionRef."
  def session(id) do
    case Elixos.Agents.whereis(id) do
      nil -> {:error, :unknown_agent}
      pid -> {:ok, ElixosHost.SessionOwner.session(pid)}
    end
  end

  @doc "An idle checkpoint plus Elixos' identity-only lifecycle snapshot."
  def snapshot(id) do
    with {:ok, session} <- session(id),
         :ok <- OhMyJido.checkpoint(session),
         do: Elixos.Agents.snapshot(id)
  end

  def stop(id), do: Elixos.Agents.stop(id)
end
