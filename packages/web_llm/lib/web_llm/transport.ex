defmodule WebLLM.Transport do
  @moduledoc """
  How a WebLLM request reaches the page that runs the model.

  A transport implements the `Finch.stream/5` contract: it receives the
  final `Finch.Request`, calls `fun` with `{:status, code}`,
  `{:headers, headers}` and `{:data, binary}` entries, and returns
  `{:ok, acc}` or `{:error, exception, acc}`.

    * `WebLLM.Live.Transport` (default) sends the request to a browser over
      its Phoenix LiveView socket.
    * `WebLLM.Popcorn.FetchStream` uses the page's `fetch` from a BEAM that
      runs in the page itself.

  Choose with `config :web_llm, transport: Module`.

  Both talk to the page through the same messages. A request is
  `%{"id", "method", "url", "headers", "body"}` (see `payload/2`). The page
  answers with events carrying the request id and a `"type"`: `"status"`
  (`"status"`), `"headers"` (`"headers"`, a list of `[name, value]`),
  `"data"` (`"data"`), then `"done"`, or `"error"` (`"message"`) at any point.
  `apply_event/3` folds one event into the caller's accumulator.
  """

  @typedoc "Accumulator threaded through the stream callback."
  @type acc :: term()

  @typedoc "One `Finch.stream/5` entry."
  @type entry ::
          {:status, non_neg_integer()}
          | {:headers, [{String.t(), String.t()}]}
          | {:data, binary()}

  @callback stream(Finch.Request.t(), term(), acc(), (entry(), acc() -> acc()), keyword()) ::
              {:ok, acc()} | {:error, Exception.t(), acc()}

  @doc "The configured transport module."
  @spec module() :: module()
  def module, do: Application.get_env(:web_llm, :transport, WebLLM.Live.Transport)

  @doc """
  The LiveView client a request is for: the `#{WebLLM.client_header()}`
  header, else the `/clients/<client>/` segment of the URL, else
  `config :web_llm, :default_client`.
  """
  @spec client(Finch.Request.t()) ::
          {:ok, WebLLM.client()} | {:error, :no_client | :invalid_client}
  def client(%Finch.Request{headers: headers, path: path}) do
    header = Enum.find_value(headers, &client_header/1)

    case header || path_client(path) || Application.get_env(:web_llm, :default_client) do
      nil -> {:error, :no_client}
      client -> if WebLLM.client?(client), do: {:ok, client}, else: {:error, :invalid_client}
    end
  end

  defp client_header({name, value}),
    do: if(String.downcase(name) == WebLLM.client_header(), do: value)

  defp path_client(path) do
    case String.split(path || "", "/", trim: true) do
      ["clients", client | _rest] -> client
      _segments -> nil
    end
  end

  @doc "Encodes a request for the page, under the request id `id`."
  @spec payload(Finch.Request.t(), String.t()) :: map()
  def payload(%Finch.Request{} = request, id) do
    %{
      "id" => id,
      "method" => request.method,
      "url" => url(request),
      "headers" => Map.new(request.headers),
      "body" => body(request.body)
    }
  end

  defp url(%Finch.Request{scheme: scheme, host: host, port: port, path: path, query: query}) do
    URI.to_string(%URI{
      scheme: Atom.to_string(scheme),
      host: host,
      port: port,
      path: path,
      query: query
    })
  end

  defp body(nil), do: ""
  defp body(body) when is_binary(body), do: body
  defp body(body) when is_list(body), do: IO.iodata_to_binary(body)

  @doc "Returns a new request id."
  @spec request_id() :: String.t()
  def request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc """
  Folds one page event into the stream: `{:cont, acc}` to keep reading,
  `{:done, acc}` at the end, or `{:error, reason}`.
  """
  @spec apply_event(map(), acc(), (entry(), acc() -> acc())) ::
          {:cont, acc()} | {:done, acc()} | {:error, term()}
  def apply_event(%{"type" => "status", "status" => status}, acc, fun) when is_integer(status),
    do: {:cont, fun.({:status, status}, acc)}

  def apply_event(%{"type" => "headers", "headers" => headers}, acc, fun) when is_list(headers),
    do: {:cont, fun.({:headers, Enum.map(headers, fn [name, value] -> {name, value} end)}, acc)}

  def apply_event(%{"type" => "data", "data" => data}, acc, fun) when is_binary(data),
    do: {:cont, fun.({:data, data}, acc)}

  def apply_event(%{"type" => "done"}, acc, _fun), do: {:done, acc}

  def apply_event(%{"type" => "error"} = event, _acc, _fun),
    do: {:error, {:page, Map.get(event, "message", "WebLLM request failed")}}

  def apply_event(event, _acc, _fun), do: {:error, {:invalid_event, event}}

  @doc """
  Req adapter (`adapter: WebLLM.Transport`) for non-streaming requests: runs
  the request through `module/0` and returns the page's complete response.
  """
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    headers = for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}
    finch = Finch.build(request.method, request.url, headers, request.body)
    timeout = Req.Request.get_option(request, :receive_timeout, 30_000)
    empty = %{status: 200, headers: [], body: []}

    case module().stream(finch, nil, empty, &collect/2, receive_timeout: timeout) do
      {:ok, acc} ->
        {request, response(acc)}

      {:error, exception, _acc} ->
        {request, exception}
    end
  end

  defp collect({:status, status}, acc), do: %{acc | status: status}
  defp collect({:headers, headers}, acc), do: %{acc | headers: acc.headers ++ headers}
  defp collect({:data, data}, acc), do: %{acc | body: [acc.body | data]}

  defp response(%{status: status, headers: headers, body: body}) do
    Req.Response.new(
      status: status,
      headers: Enum.group_by(headers, &String.downcase(elem(&1, 0)), &elem(&1, 1)),
      body: IO.iodata_to_binary(body)
    )
  end
end
