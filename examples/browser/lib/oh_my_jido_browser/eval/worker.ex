defmodule OhMyJidoBrowser.Eval.Worker do
  @moduledoc """
  The Elixir side of one browser Eval kernel.

  The Eval kernel controller monitors this process as the kernel's worker.
  Page code sends it the cell's output, display values and host tool calls,
  which it forwards to the controller's bridge for the active cell only. When
  it stops, it closes the page-side kernel.
  """

  use GenServer

  alias OhMyJido.Eval.Bridge
  alias Popcorn.JS

  @doc "Starts a worker linked to the calling kernel controller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Marks `request` as the active cell until the next activation."
  @spec activate(pid(), map()) :: :ok
  def activate(worker, request),
    do: GenServer.call(worker, {:activate, request.generation, request.id})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       bridge: Keyword.fetch!(opts, :bridge),
       id: Keyword.fetch!(opts, :id),
       close: Keyword.fetch!(opts, :close),
       active: nil
     }}
  end

  @impl true
  def handle_call({:activate, generation, id}, _from, state),
    do: {:reply, :ok, %{state | active: {generation, id}}}

  def handle_call(["tool", name, parameters], _from, %{active: {generation, id}} = state)
      when is_binary(name) and is_map(parameters) do
    reply = Bridge.call(state.bridge, generation, id, {:tool, name, parameters}, :infinity)
    {:reply, reply, state}
  end

  def handle_call(["tool", _name, _parameters], _from, state),
    do: {:reply, %{"ok" => false, "error" => "no active cell"}, state}

  @impl true
  def handle_info({:wasm, ["output", stream, text]}, state)
      when stream in ["stdout", "stderr"] and is_binary(text) do
    forward(state, {:output, String.to_existing_atom(stream), text, false})
  end

  def handle_info({:wasm, ["display", text]}, state) when is_binary(text),
    do: forward(state, {:display, text})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = JS.run(state.close, %{id: state.id})
    :ok
  end

  defp forward(%{active: {generation, id}} = state, operation) do
    _ = Bridge.call(state.bridge, generation, id, operation)
    {:noreply, state}
  end

  defp forward(state, _operation), do: {:noreply, state}
end
