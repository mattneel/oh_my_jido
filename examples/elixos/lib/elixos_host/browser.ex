defmodule ElixosHost.Browser do
  @moduledoc "Authorized access to Elixos.Browser's real singleton API, not invented native contexts."
  @behaviour OhMyJido.Extensions.Browser

  alias ElixosHost.BrowserLease
  alias OhMyJido.Tool

  @snapshot "({url: location.href, title: document.title, content: document.body ? document.body.innerText : ''})"
  @operations [:navigate, :snapshot, :eval, :screenshot]

  @impl true
  def invoke(_context, %{operation: :close}, _options),
    do: {:error, :browser_page_close_unavailable}

  def invoke(_context, %{operation: operation}, _options) when operation in [:click, :fill],
    do: {:error, :browser_operation_unavailable}

  def invoke(context, %{operation: :release, page_id: page_id} = request, options)
      when map_size(request) == 2 do
    with {:ok, lease} <- lease(options),
         :ok <- Tool.authorize(context, :browser, %{operation: :release, page_id: page_id}),
         :ok <- BrowserLease.release(lease, context, page_id) do
      {:ok, %{page_id: page_id, released: true, page_closed: false}}
    end
  catch
    :exit, _reason -> {:error, :browser_lease_unavailable}
  end

  def invoke(context, %{operation: operation} = request, options) when operation in @operations do
    with :ok <- valid_request(request),
         {:ok, lease} <- lease(options),
         :ok <- BrowserLease.check(lease, context, request),
         :ok <- Tool.authorize(context, :browser, %{operation: operation}),
         :ok <- authorize_effects(context, request, options) do
      BrowserLease.run(lease, context, request, fn -> execute(context, request, options) end)
    end
  catch
    :exit, _reason -> {:error, :browser_lease_unavailable}
  end

  def invoke(_context, _request, _options), do: {:error, :invalid_browser_request}

  @impl true
  def close_session(context, options) do
    case lease(options) do
      {:ok, lease} ->
        if BrowserLease.owner(lease) == {context.runtime, context.session_id},
          do: BrowserLease.release(lease, context),
          else: :ok

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _reason -> {:error, :browser_lease_unavailable}
  end

  defp lease(options) do
    cond do
      not Keyword.get(options, :browser_exclusive, false) ->
        {:error, :browser_exclusive_routing_required}

      is_nil(Keyword.get(options, :browser_lease)) ->
        {:error, {:capability_unavailable, :browser}}

      true ->
        {:ok, Keyword.fetch!(options, :browser_lease)}
    end
  end

  defp authorize_effects(context, %{operation: :navigate} = request, options) do
    with :ok <- network_boundary(context, request, options),
         :ok <- Tool.authorize(context, :network, %{operation: :navigate, url: request.url}),
         :ok <- script_authorization(context, @snapshot, :snapshot, true) do
      :ok
    end
  end

  defp authorize_effects(context, %{operation: :eval} = request, options) do
    # Arbitrary page script can issue requests: a script grant never implies a network grant.
    with :ok <- network_boundary(context, request, options),
         :ok <- Tool.authorize(context, :network, %{operation: :browser_eval}),
         :ok <- script_authorization(context, request.script, :eval, false) do
      :ok
    end
  end

  defp authorize_effects(context, %{operation: :snapshot}, _options),
    do: script_authorization(context, @snapshot, :snapshot, true)

  defp authorize_effects(_context, %{operation: :screenshot}, _options), do: :ok

  defp script_authorization(context, script, operation, read_only) do
    digest = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)

    Tool.authorize(context, :browser_script, %{
      operation: operation,
      read_only: read_only,
      script_sha256: digest,
      script: script
    })
  end

  defp network_boundary(context, request, options) do
    case Keyword.get(options, :network_boundary) do
      {module, config} ->
        case module.authorize(context, request, config) do
          :ok -> :ok
          {:error, _reason} = error -> error
          _invalid -> {:error, :browser_network_boundary_failed}
        end

      nil ->
        {:error, :browser_network_boundary_required}
    end
  end

  defp execute(context, %{operation: :navigate} = request, options) do
    with {:ok, _text} <- Elixos.Browser.navigate(request.url),
         {:ok, snapshot} <- snapshot(request.max_output_bytes),
         :ok <- network_boundary(context, %{operation: :observe, url: snapshot.url}, options) do
      {:ok, snapshot}
    else
      {:error, reason} -> uncertain(reason)
    end
  rescue
    _error -> uncertain(:browser_service_failed)
  catch
    _kind, _reason -> uncertain(:browser_service_failed)
  end

  defp execute(_context, %{operation: :snapshot} = request, _options),
    do: snapshot(request.max_output_bytes)

  defp execute(_context, %{operation: :eval} = request, _options) do
    with {:ok, value} <- Elixos.Browser.eval(request.script),
         {:ok, json} <- Jason.encode(value),
         true <- byte_size(json) <= request.max_output_bytes do
      {:ok, %{value: value, trust: :untrusted}}
    else
      false -> {:error, :browser_output_limit}
      {:error, _reason} -> uncertain(:browser_script_failed)
    end
  rescue
    _error -> uncertain(:browser_service_failed)
  catch
    _kind, _reason -> uncertain(:browser_service_failed)
  end

  defp execute(_context, %{operation: :screenshot} = request, _options) do
    with {:ok, png} <- Elixos.Browser.screenshot(),
         true <- is_binary(png) and byte_size(png) <= request.max_output_bytes do
      {:ok, %{mime_type: "image/png", data_base64: Base.encode64(png), trust: :untrusted}}
    else
      false -> {:error, :browser_output_limit}
      {:error, _reason} -> uncertain(:browser_capture_failed)
    end
  rescue
    _error -> uncertain(:browser_service_failed)
  catch
    _kind, _reason -> uncertain(:browser_service_failed)
  end

  defp snapshot(cap) do
    with {:ok, %{"url" => url, "title" => title, "content" => content}} <-
           Elixos.Browser.eval(@snapshot),
         true <- Enum.all?([url, title, content], &(is_binary(&1) and String.valid?(&1))),
         true <- byte_size(url) <= 4096 and valid_url?(url) do
      {:ok,
       %{
         url: url,
         title: clip(title, 512),
         content: clip(content, cap),
         truncated: byte_size(content) > cap or byte_size(title) > 512,
         trust: :untrusted
       }}
    else
      _invalid -> uncertain(:invalid_browser_snapshot)
    end
  end

  defp valid_request(request) do
    required =
      case request.operation do
        :navigate -> [:url]
        :eval -> [:page_id, :script]
        _read -> [:page_id]
      end

    allowed =
      [:operation, :timeout_ms, :max_output_bytes] ++
        required ++
        if(request.operation == :navigate, do: [:page_id], else: [])

    timeout = Map.get(request, :timeout_ms)
    cap = Map.get(request, :max_output_bytes)

    cond do
      not Enum.all?(required, &Map.has_key?(request, &1)) ->
        {:error, :invalid_browser_request}

      Enum.any?(Map.keys(request), &(&1 not in allowed)) ->
        {:error, :invalid_browser_request}

      not is_integer(timeout) or timeout not in 1..120_000 ->
        {:error, :invalid_browser_deadline}

      not is_integer(cap) or cap not in 1..1_048_576 ->
        {:error, :invalid_browser_output_bound}

      Map.has_key?(request, :url) and not valid_url?(request.url) ->
        {:error, :invalid_browser_url}

      Map.has_key?(request, :page_id) and not valid_text?(request.page_id, 256) ->
        {:error, :invalid_browser_page}

      Map.has_key?(request, :script) and not valid_text?(request.script, 8192) ->
        {:error, :invalid_browser_script}

      true ->
        :ok
    end
  end

  defp valid_url?(url) do
    valid_text?(url, 4096) and
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] ->
          is_binary(host) and host != "" and not Regex.match?(~r/[\s\x00-\x1f\x7f]/u, url)

        _invalid ->
          false
      end
  end

  defp valid_text?(text, cap),
    do:
      is_binary(text) and byte_size(text) in 1..cap and String.valid?(text) and
        not String.contains?(text, <<0>>)

  defp clip(text, cap) when byte_size(text) <= cap, do: text
  defp clip(text, cap), do: valid_prefix(binary_part(text, 0, cap))

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end

  defp uncertain(reason), do: {:error, %{reason: reason, effect: :uncertain}}
end
