# Modified by Oh-My-Jido contributors, 2026-10-13: opt-in model-bound normalization
# before HTTP, in-process and WebSocket streaming diagnostics and propagation.
# Original ReqLLM 1.28.0: Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule ReqLLM.Streaming.Failure do
  @moduledoc false

  alias ReqLLM.MapAccess

  require Logger

  @retryable_transport_reasons [:closed, :timeout, :econnrefused, :pool_not_available]

  @type classification ::
          {:api, non_neg_integer(), term() | nil, boolean()}
          | {:transport, term(), boolean()}
          | :cancelled
          | :unknown
  @type api_error :: %ReqLLM.Error.API.Request{}

  @doc "Version of the opt-in streaming error boundary supported by this package."
  @spec normalization_version() :: pos_integer()
  def normalization_version, do: 1

  @doc false
  def error_context(provider_mod, model, opts),
    do: {Keyword.get(opts, :stream_error_normalizer) || provider_mod, model}

  @doc false
  def build_failure(reason, stage, context) do
    reason = normalize(reason, context)
    Logger.error("Failed to build streaming request: stage=#{stage}, kind=#{diagnostic_kind(reason)}")
    if normalizer?(context), do: {:error, reason}, else: {:error, {stage, reason}}
  end

  @doc false
  @spec normalizer?({module() | (term(), LLMDB.Model.t() -> term()), LLMDB.Model.t()} | nil) :: boolean()
  def normalizer?({callback, _model}) when is_function(callback, 2), do: true
  def normalizer?({provider_mod, _model}) when is_atom(provider_mod),
    do: function_exported?(provider_mod, :normalize_stream_error, 2)

  def normalizer?(_context), do: false

  @doc false
  @spec normalize(term(), {module() | (term(), LLMDB.Model.t() -> term()), LLMDB.Model.t()} | nil) :: term()
  def normalize(reason, {provider_mod, model} = context) do
    if normalizer?(context) do
      normalized =
        if is_function(provider_mod, 2),
          do: provider_mod.(reason, model),
          else: provider_mod.normalize_stream_error(reason, model)
      if normalized == :cancelled or is_exception(normalized),
        do: normalized,
        else: normalization_failure(reason)
    else
      reason
    end
  rescue
    _error -> normalization_failure(reason)
  catch
    _kind, _error -> normalization_failure(reason)
  end

  def normalize(reason, _context), do: reason

  defp normalization_failure(reason) do
    status = if is_map(reason), do: Map.get(reason, :status)
    status = if is_integer(status) and status in 100..599, do: status
    ReqLLM.Error.API.Request.exception(reason: "Stream error normalization failed", status: status, retryable: false)
  end

  @doc false
  def diagnostic_kind(%{code: code}) when is_atom(code) and not is_nil(code), do: code
  def diagnostic_kind(%{__struct__: module}) when is_atom(module), do: module
  def diagnostic_kind(_reason), do: :unknown

  @spec classify(term()) :: classification()
  def classify(%ReqLLM.Error.API.Request{status: status} = error) when is_integer(status) do
    provider_code = error.provider_code || provider_code(error.response_body)
    retryable = boolean_or_default(error.retryable, retryable_status?(status))
    {:api, status, provider_code, retryable}
  end

  def classify(%ReqLLM.Error.API.Request{cause: cause}) when not is_nil(cause) do
    classify(cause)
  end

  def classify(%{__struct__: _module, status: status, code: code, retryable: retryable})
      when is_integer(status) and is_atom(code) and is_boolean(retryable),
      do: {:api, status, Atom.to_string(code), retryable}

  def classify(%Finch.TransportError{} = error) do
    transport_classification(transport_reason(error))
  end

  def classify(%{__struct__: module, reason: reason})
      when module in [Mint.TransportError, Req.TransportError, Finch.Error] do
    transport_classification(reason)
  end

  def classify(reason) when reason in [:cancelled, :canceled], do: :cancelled

  def classify({wrapper, reason})
      when wrapper in [:error, :exit, :throw, :shutdown, :http_task_failed] do
    classify(reason)
  end

  def classify(_reason), do: :unknown

  @spec log(term()) :: classification()
  def log(reason) do
    case classify(reason) do
      {:api, status, _provider_code, retryable} = classification ->
        Logger.warning(
          "Streaming provider/API request failed: " <>
            "status=#{status}, " <>
            "retryable=#{retryable}, " <>
            "kind=#{diagnostic_kind(reason)}"
        )

        classification

      {:transport, _transport_reason, retryable} = classification ->
        Logger.error(
          "Finch streaming transport failed: " <>
            "retryable=#{retryable}, " <>
            "kind=#{diagnostic_kind(reason)}"
        )

        classification

      :cancelled ->
        :cancelled

      :unknown ->
        Logger.error("Streaming request failed: kind=#{diagnostic_kind(reason)}")
        :unknown
    end
  end

  @spec api_error(non_neg_integer(), term(), list(), keyword()) :: api_error()
  def api_error(status, body, headers, opts \\ []) when is_integer(status) do
    response_body = normalize_response_body(body)
    error_body = error_body(response_body)

    ReqLLM.Error.API.Request.exception(
      reason: error_message(error_body, status, Keyword.get(opts, :use_body_as_reason?, false)),
      status: status,
      response_body: error_body,
      headers: headers,
      provider_code: provider_code(error_body),
      retryable: retryable_status?(status)
    )
  end

  defp transport_classification(reason) do
    {:transport, reason, reason in @retryable_transport_reasons}
  end

  defp transport_reason(%Finch.TransportError{source: source, reason: reason}) do
    case source do
      %Mint.TransportError{reason: source_reason} -> source_reason
      _ -> reason
    end
  end

  defp normalize_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp normalize_response_body(body), do: body

  defp error_body(body) when is_map(body) do
    case MapAccess.get(body, :error) do
      error when is_map(error) -> error
      _other -> body
    end
  end

  defp error_body(body), do: body

  defp error_message(body, status, _use_body_as_reason?) when is_map(body) do
    case MapAccess.get(body, :message) do
      message when is_binary(message) and message != "" -> message
      _other -> "HTTP #{status}"
    end
  end

  defp error_message(body, _status, true) when is_binary(body) and body != "", do: body
  defp error_message(_body, status, _use_body_as_reason?), do: "HTTP #{status}"

  defp provider_code(body) when is_map(body) do
    MapAccess.get(body, :code) || MapAccess.get(body, :type)
  end

  defp provider_code(_body), do: nil

  defp retryable_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_status?(status) when status in 500..599, do: true
  defp retryable_status?(_status), do: false

  defp boolean_or_default(value, _default) when is_boolean(value), do: value
  defp boolean_or_default(_value, default), do: default
end
