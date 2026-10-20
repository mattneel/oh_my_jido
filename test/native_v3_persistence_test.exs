defmodule OhMyJido.NativeV3PersistenceTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Persistence

  defmodule TokenFile do
    @behaviour Jido.Persistence.Adapter

    @impl true
    def get(key, opts) do
      with {:ok, bytes} <- Jido.Persistence.File.get(key, opts),
           do: {:ok, bytes, :crypto.hash(:sha256, bytes)}
    end

    @impl true
    def compare_and_swap(key, {:token, token}, bytes, opts) do
      case get(key, opts) do
        {:ok, current, ^token} ->
          Jido.Persistence.File.compare_and_swap(key, current, bytes, opts)

        _stale ->
          {:error, :conflict}
      end
    end

    def compare_and_swap(key, condition, bytes, opts),
      do: Jido.Persistence.File.compare_and_swap(key, condition, bytes, opts)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-v3-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{store: {Jido.Persistence.File, path: root}}
  end

  test "runtime-selected native profiles retain their embedded definition across checkpoint restore",
       %{store: {_adapter, opts}} do
    context = %OhMyJido.Context{
      session_id: "configured-native",
      workspace: Keyword.fetch!(opts, :path),
      model: "anthropic:claude-haiku-4-5",
      permissions: MapSet.new([:read]),
      tools: [OhMyJido.Tools.Read]
    }

    config = [
      tool_timeout_ms: 2_000,
      max_iterations: 4,
      max_effects: 16,
      run_timeout_ms: 10_000
    ]

    assert {:ok, agent} = OhMyJido.CodingAgent.new(id: context.session_id)
    assert {:ok, configured} = OhMyJido.CodingAgent.configure(agent, context, config)
    assert configured.module == OhMyJido.CodingAgent
    assert configured.vsn == nil
    assert {:ok, checkpoint} = Jido.Agent.checkpoint(configured)
    assert checkpoint.definition == Jido.Agent.definition(configured)
    assert {:ok, restored} = Jido.Agent.restore(OhMyJido.CodingAgent, checkpoint)
    assert restored == configured
  end

  test "native byte CAS rejects stale writes without losing the committed receipt", %{
    store: store
  } do
    identity = {__MODULE__, "durable-session"}
    initial = %{version: 1, effects: %{"effect" => %{status: :running}}}
    committed = put_in(initial, [:effects, "effect", :status], :completed)

    assert {:error, :not_found} = Persistence.read_session(store, identity)

    assert {:ok, first_condition} =
             Persistence.write_session(store, identity, initial, :not_found)

    assert {:ok, ^initial, ^first_condition} = Persistence.read_session(store, identity)

    assert {:ok, condition} =
             Persistence.write_session(store, identity, committed, first_condition)

    assert {:error, :conflict} =
             Persistence.write_session(store, identity, initial, first_condition)

    assert {:error, :conflict} = Persistence.write_session(store, identity, initial, :not_found)
    assert {:ok, ^committed, ^condition} = Persistence.read_session(store, identity)
  end

  test "session keys isolate host runtimes and native Agent persistence records", %{store: store} do
    first = {__MODULE__.First, "shared-id"}
    second = {__MODULE__.Second, "shared-id"}
    saved = %{version: 1, conversation: []}

    assert Persistence.session_key(first) != Persistence.session_key(second)
    assert {:ok, _condition} = Persistence.write_session(store, first, saved, :not_found)
    assert {:error, :not_found} = Persistence.read_session(store, second)
  end

  test "native opaque CAS tokens survive successive session commits", %{store: {_adapter, opts}} do
    store = {TokenFile, opts}
    identity = {__MODULE__, "token-session"}
    initial = %{version: 1, seq: 1}
    next = %{initial | seq: 2}

    assert {:ok, {:token, first} = condition} =
             Persistence.write_session(store, identity, initial, :not_found)

    assert {:ok, {:token, second} = next_condition} =
             Persistence.write_session(store, identity, next, condition)

    refute first == second
    assert {:ok, ^next, ^next_condition} = Persistence.read_session(store, identity)
    assert {:error, :conflict} = Persistence.write_session(store, identity, initial, condition)
  end

  test "corrupt bytes fail closed instead of restoring an arbitrary term", %{
    store: {adapter, opts} = store
  } do
    identity = {__MODULE__, "corrupt"}
    key = Persistence.session_key(identity)
    assert :ok = adapter.put(key, <<0, 1, 2>>, opts)
    assert {:error, :invalid_session_checkpoint} = Persistence.read_session(store, identity)
  end
end
