defmodule OhMyJido.Extensions.Research do
  @moduledoc """
  Narrow contract for approved host search and page-reading services.

  Bind `invoke/3` under `context.adapters.research`. Search receives a query and
  result limit; read receives a credential-free HTTP(S) URL. No tool discovery,
  RPC method, shell command, cookies or arbitrary request headers are admitted.
  Every call is a sensitive external effect approved through `Tool.authorize/3`.
  The host must constrain origins, redirects and provider use, honor deadlines,
  and release request/connection resources before returning. Persistent resources
  belong to the host and may be closed by its optional `close_session/2` hook.

  Search replies are `%{results: [%{url: url, title: title, snippet: text}]}`.
  Read replies are `%{url: url, title: title, content: text}`. Optional
  `truncated: true` retains provider incompleteness. Content is returned only as
  untrusted evidence, never as host policy or instructions. Search URLs have a
  separate 4096-byte bound; titles and snippets share the requested text budget.
  """

  import OhMyJido.Extensions.Text, only: [text: 2]

  alias OhMyJido.{Context, Host, Tool}

  @type request :: %{
          required(:operation) => :search | :read,
          required(:timeout_ms) => pos_integer(),
          required(:max_output_bytes) => pos_integer(),
          optional(:query) => String.t(),
          optional(:url) => String.t(),
          optional(:limit) => pos_integer()
        }
  @callback invoke(Context.t(), request(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback close_session(Context.t(), keyword()) :: :ok | {:error, term()}
  @optional_callbacks close_session: 2

  @doc false
  def perform(context, params) do
    with {:ok, request} <- request(context, params),
         :ok <- Tool.authorize(context, :research, effect(request)),
         {:ok, result} <- invoke(context, request) do
      response(request, result)
    end
  end

  defp invoke(context, request) do
    case Host.call(context, :invoke, [:research, request]) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:capability_unavailable, :research}} = error ->
        error

      {:error, %{effect: :uncertain}} ->
        {:error, %{reason: :host_callback_failed, capability: :research, effect: :uncertain}}

      {:error, _reason} ->
        {:error, %{reason: :host_callback_failed, capability: :research, effect: :unknown}}

      _invalid ->
        {:error, {:invalid_host_response, :research}}
    end
  end

  @doc "Human-initiated search/read smoke against a configured real host; no automatic requests."
  def smoke(execution_context, query, expected_url, expected_content, opts \\ []) do
    if Keyword.get(opts, :human_initiated, false) and is_binary(expected_content) and
         expected_content != "" and byte_size(expected_content) <= 4096 do
      with {:ok, context} <- Context.fetch(execution_context),
           {:ok, search} <-
             OhMyJido.Tools.Research.run(%{operation: "search", query: query}, context),
           true <- Enum.any?(search.results, &(&1.url == expected_url)),
           {:ok, read} <-
             OhMyJido.Tools.Research.run(%{operation: "read", url: expected_url}, context),
           true <- String.contains?(read.content, expected_content) do
        {:ok, %{observed: true, search: search, read: read}}
      else
        false -> {:error, :expected_content_not_observed}
        {:error, _reason} = error -> error
      end
    else
      {:error, :human_initiated_required}
    end
  end

  defp request(context, %{operation: "search"} = params) do
    with true <- valid_text?(Map.get(params, :query), 4096),
         false <- Map.has_key?(params, :url),
         {:ok, cap} <- output_cap(context, params) do
      {:ok,
       %{
         operation: :search,
         query: params.query,
         limit: params.limit,
         timeout_ms: params.timeout_ms,
         max_output_bytes: cap
       }}
    else
      _invalid -> {:error, :invalid_research_request}
    end
  end

  defp request(context, %{operation: "read"} = params) do
    with true <- valid_url?(Map.get(params, :url)),
         false <- Map.has_key?(params, :query),
         {:ok, cap} <- output_cap(context, params) do
      {:ok,
       %{operation: :read, url: params.url, timeout_ms: params.timeout_ms, max_output_bytes: cap}}
    else
      _invalid -> {:error, :invalid_research_request}
    end
  end

  defp output_cap(context, params) do
    case Map.get(context.limits, :research_output_bytes, 131_072) do
      cap when is_integer(cap) and cap > 0 -> {:ok, min(cap, params.max_output_bytes)}
      _invalid -> {:error, :invalid_research_limit}
    end
  end

  defp effect(request) do
    request
    |> Map.take([:operation, :query, :url, :limit])
    |> Map.merge(%{sensitive: true, external: true, mutates: false})
  end

  defp response(%{operation: :read} = request, %{url: url, content: content} = result) do
    title = Map.get(result, :title, "")

    if valid_url?(url) and is_binary(content) and String.valid?(content) and
         is_binary(title) and String.valid?(title) do
      {title, title_clipped} = text(title, min(512, request.max_output_bytes))
      {content, content_clipped} = text(content, request.max_output_bytes - byte_size(title))

      {:ok,
       %{
         operation: :read,
         url: url,
         title: title,
         content: content,
         trust: :untrusted,
         truncated:
           title_clipped or content_clipped or Map.get(result, :truncated, false) == true,
         limits: %{text_bytes: request.max_output_bytes, url_bytes: 4096}
       }}
    else
      {:error, {:invalid_host_response, :research}}
    end
  end

  defp response(%{operation: :search} = request, %{results: results} = result)
       when is_list(results) do
    selected = Enum.take(results, request.limit + 1)

    with {:ok, entries, _remaining, clipped} <-
           entries(Enum.take(selected, request.limit), request.max_output_bytes, [], false) do
      {:ok,
       %{
         operation: :search,
         results: entries,
         trust: :untrusted,
         truncated:
           clipped or length(selected) > request.limit or
             Map.get(result, :truncated, false) == true,
         limits: %{text_bytes: request.max_output_bytes, results: request.limit, url_bytes: 4096}
       }}
    end
  end

  defp response(_request, _result), do: {:error, {:invalid_host_response, :research}}

  defp entries([], remaining, acc, clipped), do: {:ok, Enum.reverse(acc), remaining, clipped}
  defp entries([_entry | _rest], 0, acc, _clipped), do: {:ok, Enum.reverse(acc), 0, true}

  defp entries([%{url: url, title: title, snippet: snippet} | rest], remaining, acc, clipped) do
    if valid_url?(url) and is_binary(title) and String.valid?(title) and
         is_binary(snippet) and String.valid?(snippet) do
      {title, title_clipped} = text(title, min(512, remaining))
      remaining = remaining - byte_size(title)
      {snippet, snippet_clipped} = text(snippet, remaining)
      remaining = remaining - byte_size(snippet)
      entry = %{url: url, title: title, snippet: snippet}
      entries(rest, remaining, [entry | acc], clipped or title_clipped or snippet_clipped)
    else
      {:error, {:invalid_host_response, :research}}
    end
  end

  defp entries(_entries, _remaining, _acc, _clipped),
    do: {:error, {:invalid_host_response, :research}}

  defp valid_url?(url), do: OhMyJido.Extensions.URL.valid?(url)

  defp valid_text?(value, cap),
    do:
      is_binary(value) and value != "" and byte_size(value) <= cap and String.valid?(value) and
        not String.contains?(value, <<0>>)
end
