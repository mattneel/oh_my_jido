if Code.ensure_loaded?(Popcorn.JS) do
  defmodule WebLLM.Popcorn.FetchStream do
    @moduledoc """
    Streams HTTP requests through the browser's `fetch()` from a BEAM running
    in the page (Popcorn).

    A BEAM compiled to WebAssembly has no sockets, so Finch cannot connect.
    Use this module for every ReqLLM request in such an app, WebLLM or not:

        config :req_llm, finch_stream_adapter: WebLLM.Popcorn.FetchStream
        config :web_llm, transport: WebLLM.Popcorn.FetchStream

    Requests go through `globalThis.webLLMFetch` when the page installed the
    WebLLM bridge's fetch shim (it answers `https://web-llm.invalid` and passes
    everything else to `fetch`), otherwise through `fetch`. Response chunks
    reach the caller as the browser reads them. Each wait for the next chunk is
    bounded by `:receive_timeout`. When the calling process exits, a watcher
    aborts the browser request.
    """

    @behaviour WebLLM.Transport

    alias Popcorn.JS

    @start """
    ({id, url, method, headers, body, pid}, {send}) => {
      const controller = new AbortController();
      const active = (globalThis.__webLLMFetches ??= new Map());
      active.set(id, controller);

      (async () => {
        try {
          const response = await (globalThis.webLLMFetch ?? fetch)(url, {
            method,
            headers,
            body: body ?? undefined,
            signal: controller.signal,
            credentials: "omit",
            redirect: "error",
            cache: "no-store",
            referrerPolicy: "no-referrer",
          });
          await send(pid, ["status", id, response.status, [...response.headers]]);
          const reader = response.body.getReader();
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            await send(pid, ["data", id, value]);
          }
          await send(pid, ["done", id]);
        } catch (error) {
          const reason = `${error?.name ?? "Error"}: ${error?.message ?? error}`;
          await send(pid, ["error", id, reason]).catch(() => {});
        } finally {
          active.delete(id);
        }
      })();

      return true;
    }
    """

    @abort """
    ({id}) => {
      globalThis.__webLLMFetches?.get(id)?.abort();
      return true;
    }
    """

    @impl WebLLM.Transport
    def stream(%Finch.Request{} = request, _finch_name, acc, fun, opts) do
      id = WebLLM.Transport.request_id()
      timeout = Keyword.get(opts, :receive_timeout, 30_000)
      owner = self()
      watcher = spawn(fn -> watch(owner, id) end)

      try do
        case JS.run(@start, start_args(request, id, owner)) do
          {:ok, true} -> receive_chunks(id, acc, fun, timeout)
          {:ok, _other} -> {:error, %Req.TransportError{reason: :browser_fetch_unavailable}, acc}
          {:error, reason} -> {:error, %Req.TransportError{reason: {:browser_fetch, reason}}, acc}
        end
      after
        send(watcher, :finished)
      end
    end

    defp start_args(request, id, owner) do
      payload = WebLLM.Transport.payload(request, id)

      %{
        id: id,
        url: payload["url"],
        method: payload["method"],
        headers: Enum.map(request.headers, fn {name, value} -> [name, value] end),
        body: if(payload["body"] == "", do: nil, else: payload["body"]),
        pid: owner
      }
    end

    defp receive_chunks(id, acc, fun, timeout) do
      receive do
        {:wasm, ["status", ^id, status, headers]} ->
          acc = fun.({:status, status}, acc)
          acc = fun.({:headers, Enum.map(headers, fn [name, value] -> {name, value} end)}, acc)
          receive_chunks(id, acc, fun, timeout)

        {:wasm, ["data", ^id, chunk]} ->
          receive_chunks(id, fun.({:data, chunk}, acc), fun, timeout)

        {:wasm, ["done", ^id]} ->
          {:ok, acc}

        {:wasm, ["error", ^id, reason]} ->
          {:error, %Req.TransportError{reason: {:browser_fetch, reason}}, acc}
      after
        timeout ->
          abort(id)
          {:error, %Req.TransportError{reason: :timeout}, acc}
      end
    end

    defp watch(owner, id) do
      monitor = Process.monitor(owner)

      receive do
        :finished -> :ok
        {:DOWN, ^monitor, :process, ^owner, _reason} -> abort(id)
      end
    end

    defp abort(id) do
      _ = JS.run(@abort, %{id: id})
      :ok
    end
  end
end
