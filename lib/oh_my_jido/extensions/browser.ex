defmodule OhMyJido.Extensions.Browser do
  @moduledoc """
  Contract and boundary for a host-owned browser adapter, not a browser runtime.

  Bind a module implementing `invoke/3` in `context.adapters.browser`. Requests
  contain only the documented operations and bounded fields, never JavaScript,
  RPC method names, credentials, arbitrary headers or protocol messages. The
  adapter must enforce approved origins, redirects, downloads, popups and page
  ownership by session. It must respect `timeout_ms` and `max_output_bytes`.

  Navigation may create a page and must return a bounded opaque `page_id`.
  Other operations consume that handle. Close must release the actual page and
  return `closed: true`; uncertain cleanup is an error, not a successful close.
  Host adapters own cancellation and session teardown, including handles created
  before an interrupted or invalid response. They may implement `close_session/2`
  for the harness's trusted session-cleanup hook. No resources are owned here.

  Returned page text is labeled untrusted, including instructions found on pages.
  A grant is not approval: navigation, clicks and fills are sensitive external
  effects. Snapshot and close do not grant navigation or arbitrary execution.
  """

  import OhMyJido.Extensions.Text, only: [text: 2]

  alias OhMyJido.{Context, Host, Tool}

  @type request :: %{
          required(:operation) => :navigate | :snapshot | :click | :fill | :close,
          required(:timeout_ms) => pos_integer(),
          required(:max_output_bytes) => pos_integer(),
          optional(:page_id) => String.t(),
          optional(:url) => String.t(),
          optional(:selector) => String.t(),
          optional(:value) => String.t()
        }
  @callback invoke(Context.t(), request(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback close_session(Context.t(), keyword()) :: :ok | {:error, term()}
  @optional_callbacks close_session: 2

  @doc false
  def perform(context, params) do
    with {:ok, request} <- request(context, params),
         :ok <- Tool.authorize(context, :browser, effect(request)),
         {:ok, response} <- invoke(context, request) do
      response(request, response)
    end
  end

  defp invoke(context, request) do
    case Host.call(context, :invoke, [:browser, request]) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:capability_unavailable, :browser}} = error ->
        error

      {:error, %{effect: :uncertain}} ->
        {:error, %{reason: :host_callback_failed, capability: :browser, effect: :uncertain}}

      {:error, _reason} ->
        {:error, %{reason: :host_callback_failed, capability: :browser, effect: :unknown}}

      _invalid ->
        {:error, {:invalid_host_response, :browser}}
    end
  end

  @doc """
  Human-initiated real-host smoke: navigate, observe expected content and close.

  Nothing runs automatically. Supply `human_initiated: true` and an explicitly
  configured browser adapter; the normal approval policy still applies. The
  host, rather than this helper, controls network access and credentials.
  """
  def smoke(execution_context, url, expected_content, opts \\ []) do
    if Keyword.get(opts, :human_initiated, false) and is_binary(expected_content) and
         expected_content != "" and byte_size(expected_content) <= 4096 do
      with {:ok, context} <- Context.fetch(execution_context),
           {:ok, opened} <-
             OhMyJido.Tools.Browser.run(%{operation: "navigate", url: url}, context) do
        observation = observe_smoke(context, opened.page_id, expected_content)

        closed =
          OhMyJido.Tools.Browser.run(%{operation: "close", page_id: opened.page_id}, context)

        smoke_result(observation, closed)
      end
    else
      {:error, :human_initiated_required}
    end
  end

  defp observe_smoke(context, page_id, expected) do
    case OhMyJido.Tools.Browser.run(%{operation: "snapshot", page_id: page_id}, context) do
      {:ok, snapshot} ->
        if String.contains?(snapshot.content, expected),
          do: {:ok, %{observed: true, snapshot: snapshot}},
          else: {:error, :expected_content_not_observed}

      {:error, _reason} = error ->
        error
    end
  rescue
    error -> {:error, {:browser_observation_failed, error.__struct__}}
  catch
    kind, _reason -> {:error, {:browser_observation_failed, kind}}
  end

  defp smoke_result({:ok, result}, {:ok, %{closed: true}}),
    do: {:ok, Map.put(result, :cleanup, :confirmed)}

  defp smoke_result({:error, _reason} = error, {:ok, %{closed: true}}), do: error

  defp smoke_result(observation, {:error, reason}),
    do:
      {:error, %{reason: :browser_cleanup_unconfirmed, observation: observation, cleanup: reason}}

  defp request(context, params) do
    operation = operation(params.operation)
    required = required_fields(operation)
    supplied = Map.take(params, [:page_id, :url, :selector, :value])
    allowed = allowed_fields(operation)

    with true <- Enum.all?(required, &Map.has_key?(supplied, &1)),
         true <- Enum.all?(Map.keys(supplied), &(&1 in allowed)),
         true <- Enum.all?(supplied, fn {key, value} -> valid_field?(key, value) end),
         cap when is_integer(cap) and cap > 0 <-
           Map.get(context.limits, :browser_output_bytes, 131_072) do
      {:ok,
       Map.merge(supplied, %{
         operation: operation,
         timeout_ms: params.timeout_ms,
         max_output_bytes: min(params.max_output_bytes, cap)
       })}
    else
      _invalid -> {:error, :invalid_browser_request}
    end
  end

  defp operation("navigate"), do: :navigate
  defp operation("snapshot"), do: :snapshot
  defp operation("click"), do: :click
  defp operation("fill"), do: :fill
  defp operation("close"), do: :close

  defp required_fields(:navigate), do: [:url]
  defp required_fields(:snapshot), do: [:page_id]
  defp required_fields(:close), do: [:page_id]
  defp required_fields(:click), do: [:page_id, :selector]
  defp required_fields(:fill), do: [:page_id, :selector, :value]

  defp allowed_fields(:navigate), do: [:url, :page_id]
  defp allowed_fields(operation), do: required_fields(operation)

  defp valid_field?(:url, value), do: OhMyJido.Extensions.URL.valid?(value)

  defp valid_field?(:page_id, value), do: valid_text?(value, 256, false)
  defp valid_field?(:selector, value), do: valid_text?(value, 512, false)
  defp valid_field?(:value, value), do: valid_text?(value, 8192, true)

  defp valid_text?(value, cap, empty?) do
    is_binary(value) and byte_size(value) <= cap and String.valid?(value) and
      (empty? or value != "") and not String.contains?(value, <<0>>)
  end

  defp effect(request) do
    request
    |> Map.take([:operation, :page_id, :url, :selector])
    |> Map.merge(%{
      sensitive: request.operation in [:navigate, :click, :fill],
      external: request.operation in [:navigate, :click, :fill],
      mutates: request.operation != :snapshot,
      value_bytes: byte_size(Map.get(request, :value, ""))
    })
  end

  defp response(%{operation: :close, page_id: page_id}, %{page_id: page_id, closed: true}) do
    {:ok,
     %{operation: :close, page_id: page_id, closed: true, trust: :untrusted, truncated: false}}
  end

  defp response(%{operation: :close}, _response), do: {:error, :browser_cleanup_unconfirmed}

  defp response(request, %{page_id: page_id, content: content} = result) do
    with true <- valid_field?(:page_id, page_id),
         true <- not Map.has_key?(request, :page_id) or request.page_id == page_id,
         true <- is_binary(content) and String.valid?(content),
         true <- valid_field?(:url, Map.get(result, :url, "")),
         true <-
           is_binary(Map.get(result, :title, "")) and String.valid?(Map.get(result, :title, "")) do
      {content, clipped} = text(content, request.max_output_bytes)
      {title, title_clipped} = text(Map.get(result, :title, ""), 512)

      {:ok,
       %{
         operation: request.operation,
         page_id: page_id,
         url: result.url,
         title: title,
         content: content,
         trust: :untrusted,
         truncated: clipped or title_clipped or Map.get(result, :truncated, false) == true,
         limits: %{content_bytes: request.max_output_bytes, title_bytes: 512, url_bytes: 4096}
       }}
    else
      _invalid -> {:error, {:invalid_host_response, :browser}}
    end
  end

  defp response(_request, _result), do: {:error, {:invalid_host_response, :browser}}
end
