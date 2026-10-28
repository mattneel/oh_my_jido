if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule WebLLM.Live.Transport do
    @moduledoc """
    Streams WebLLM requests through a browser's LiveView socket.

    The request goes to the `WebLLM.Live.Component` registered for the
    request's client (see `WebLLM.Transport.client/1`), whose hook runs the
    model and pushes the response back event by event. Each wait for the next
    event is bounded by `:receive_timeout`. A timeout, or the calling process
    exiting, cancels the generation in the page; the LiveView going away ends
    the request with `:client_disconnected`.
    """

    @behaviour WebLLM.Transport

    alias WebLLM.Live.Component
    alias WebLLM.Transport

    require Logger

    @impl WebLLM.Transport
    def stream(%Finch.Request{} = request, _finch_name, acc, fun, opts) do
      with {:ok, client} <- Transport.client(request),
           {:ok, {pid, dom_id}} <- WebLLM.Live.lookup(client) do
        id = Transport.request_id()
        owner = self()
        watcher = spawn(fn -> watch(owner, pid, dom_id, id) end)
        monitor = Process.monitor(pid)
        Component.deliver(pid, dom_id, {:request, id, owner, Transport.payload(request, id)})
        target = %{id: id, pid: pid, dom_id: dom_id, monitor: monitor}

        try do
          receive_events(target, acc, fun, Keyword.get(opts, :receive_timeout, 30_000))
        after
          Process.demonitor(monitor, [:flush])
          send(watcher, :finished)
        end
      else
        {:error, reason} -> failure(reason, acc)
      end
    end

    defp receive_events(%{id: id, pid: pid, monitor: monitor} = target, acc, fun, timeout) do
      receive do
        {:web_llm, ^id, event} ->
          case Transport.apply_event(event, acc, fun) do
            {:cont, acc} -> receive_events(target, acc, fun, timeout)
            {:done, acc} -> {:ok, acc}
            {:error, reason} -> failure(reason, acc)
          end

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          failure(:client_disconnected, acc)
      after
        timeout ->
          Component.deliver(pid, target.dom_id, {:cancel, id})
          failure(:timeout, acc)
      end
    end

    # ReqLLM reports every transport failure as the same provider error, so
    # the reason is logged here. Client ids route to a browser; never log them.
    defp failure(reason, acc) do
      Logger.warning("WebLLM LiveView request failed: #{inspect(reason)}")
      {:error, %Req.TransportError{reason: reason}, acc}
    end

    defp watch(owner, pid, dom_id, id) do
      monitor = Process.monitor(owner)

      receive do
        :finished ->
          :ok

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          Component.deliver(pid, dom_id, {:cancel, id})
      end
    end
  end
end
