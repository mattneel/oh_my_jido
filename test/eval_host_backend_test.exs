defmodule OhMyJido.EvalHostBackendTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Eval}
  alias OhMyJido.Eval.Bridge

  defmodule CounterBackend do
    @behaviour OhMyJido.Eval.Backend

    @impl true
    def open(_context, opts) do
      {:ok, worker} = Agent.start(fn -> 0 end)
      seen = opts |> Keyword.take([:label, :language, :generation]) |> Map.new()
      send(Keyword.fetch!(opts, :observer), {:opened, seen, is_pid(opts[:bridge])})
      {:ok, %{worker: worker, bridge: Keyword.fetch!(opts, :bridge)}}
    end

    @impl true
    def execute(handle, request) do
      {increment, ""} = Integer.parse(request.source)
      total = Agent.get_and_update(handle.worker, &{&1 + increment, &1 + increment})

      :ok =
        Bridge.call(
          handle.bridge,
          request.generation,
          request.id,
          {:output, :stdout, "added #{increment}\n", false}
        )

      {:ok, %{status: :ok, display: Integer.to_string(total)}}
    end

    @impl true
    def interrupt(_handle, _execution_id), do: :ok

    @impl true
    def reset(handle) do
      Agent.update(handle.worker, fn _total -> 0 end)
      {:ok, handle}
    end

    @impl true
    def close(handle), do: Agent.stop(handle.worker)
  end

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "omj-host-backend-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, context} =
      Context.new(session_id: "host-backend", workspace: workspace, permissions: [:eval])

    %{context: context}
  end

  test "a host backend keeps state across cells and streams output through the bridge",
       %{context: context} do
    eval =
      start_supervised!(
        {Eval,
         backends: %{javascript: [backend: CounterBackend, observer: self(), label: "browser"]}}
      )

    assert {:ok, %{status: :ok, display: "2", stdout: "added 2\n", kernel_state: :ready}} =
             Eval.execute(eval, context, :javascript, "2")

    assert {:ok, %{status: :ok, display: "5", stdout: "added 3\n"}} =
             Eval.execute(eval, context, :javascript, "3")

    assert_received {:opened, %{label: "browser", language: :javascript, generation: 1}, true}
  end

  test "a module without the backend callbacks is rejected", %{context: context} do
    eval = start_supervised!({Eval, backends: %{python: [backend: String]}})

    assert {:error, {:invalid_backend, String}} = Eval.execute(eval, context, :python, "1")
  end
end
