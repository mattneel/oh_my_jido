if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule WebLLM.Live do
    @moduledoc """
    Reaches the browsers that host a `WebLLM.Live.Component`.

    Each connected component registers its `client` id. Any process on the
    server can then send that browser model requests (through ReqLLM and
    `WebLLM.Live.Transport`) or, when the component allows it, JavaScript to
    evaluate in the page with `eval/3`.
    """

    alias WebLLM.Live.Component

    @registry WebLLM.Live.Registry

    @doc "The LiveView process and component DOM id serving `client`."
    @spec lookup(WebLLM.client()) :: {:ok, {pid(), String.t()}} | {:error, :client_not_connected}
    def lookup(client) do
      case Registry.lookup(@registry, client) do
        [{pid, %{dom_id: dom_id}}] -> {:ok, {pid, dom_id}}
        [] -> {:error, :client_not_connected}
      end
    end

    @doc "Whether a browser is connected for `client`."
    @spec connected?(WebLLM.client()) :: boolean()
    def connected?(client), do: WebLLM.client?(client) and match?({:ok, _}, lookup(client))

    @doc """
    Evaluates `source` in the client's page and returns its JSON-safe result.
    A single expression returns its value, as in a browser console; anything
    else runs as the body of an async function and returns what it returns.

    The component must be rendered with `allow_eval={true}`. The caller is
    trusted server code: whatever reaches `source` runs with the page's full
    authority, so never pass text a model or user controls unless that is
    the intended capability.
    """
    @spec eval(WebLLM.client(), String.t(), timeout()) :: {:ok, term()} | {:error, term()}
    def eval(client, source, timeout \\ 30_000) when is_binary(source) do
      with true <- WebLLM.client?(client) || {:error, :invalid_client},
           {:ok, {pid, dom_id}} <- lookup(client) do
        id = WebLLM.Transport.request_id()
        monitor = Process.monitor(pid)
        Component.deliver(pid, dom_id, {:eval, id, self(), source})

        try do
          await_eval(id, pid, monitor, timeout)
        after
          Process.demonitor(monitor, [:flush])
          Component.deliver(pid, dom_id, {:forget, id})
        end
      end
    end

    defp await_eval(id, pid, monitor, timeout) do
      receive do
        {:web_llm_eval, ^id, %{"ok" => true} = result} -> {:ok, Map.get(result, "value")}
        {:web_llm_eval, ^id, result} -> {:error, {:page, Map.get(result, "error", "failed")}}
        {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :client_disconnected}
      after
        timeout -> {:error, :timeout}
      end
    end
  end
end
