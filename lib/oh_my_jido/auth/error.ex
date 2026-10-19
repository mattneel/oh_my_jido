defmodule OhMyJido.Auth.Error do
  @moduledoc """
  Allowlisted authentication and subscription diagnostics.

  Raw provider exceptions, HTTP requests, response messages, OAuth callbacks and
  credentials are deliberately not fields of this exception.
  """

  defexception [
    :code,
    :status,
    :request_id,
    :retry_after,
    :eligibility,
    :quota,
    provider: :openai,
    retryable: false,
    reauth_required: false
  ]

  @type t :: %__MODULE__{
          code: atom(),
          provider: atom(),
          status: integer() | nil,
          request_id: String.t() | nil,
          retry_after: non_neg_integer() | nil,
          eligibility: :eligible | :ineligible | :admission_required | nil,
          quota: map() | nil,
          retryable: boolean(),
          reauth_required: boolean()
        }

  @codes %{
    "subscription_sharing_usage_limit_exceeded" => :subscription_sharing_usage_limit_exceeded,
    "subscription_sharing_user_not_eligible" => :subscription_sharing_user_not_eligible,
    "subscription_sharing_unsupported_capability" => :subscription_sharing_unsupported_capability,
    "subscription_sharing_usage_unavailable" => :subscription_sharing_usage_unavailable,
    "subscription_sharing_user_unavailable" => :subscription_sharing_user_unavailable,
    "chatpass_v2_scope_not_authorized" => :chatpass_v2_scope_not_authorized,
    "chatpass_v2_invalid_authorization_context" => :chatpass_v2_invalid_authorization_context,
    "subscription_sharing_route_not_supported" => :subscription_sharing_route_not_supported,
    "subscription_sharing_invalid_user" => :subscription_sharing_invalid_user,
    "token_expired" => :token_expired,
    "refresh_token_expired" => :refresh_token_expired,
    "refresh_token_invalidated" => :refresh_token_invalidated,
    "invalid_refresh_token" => :invalid_refresh_token,
    "usage_limit_reached" => :usage_limit,
    "usage_limit_exceeded" => :usage_limit,
    "insufficient_quota" => :usage_limit,
    "quota_exceeded" => :usage_limit,
    "rate_limit_exceeded" => :rate_limited,
    "subscription_required" => :ineligible,
    "chatgpt_account_not_eligible" => :ineligible,
    "account_not_eligible" => :ineligible,
    "eligibility_required" => :ineligible,
    "admission_denied" => :admission_denied,
    "access_denied" => :access_denied,
    "invalid_grant" => :invalid_grant,
    "invalid_token" => :invalid_token,
    "refresh_token_reused" => :refresh_token_reused,
    "token_revoked" => :token_revoked,
    "login_required" => :reauth_required,
    "consent_required" => :consent_required,
    "insufficient_scope" => :consent_required,
    "unsupported_parameter" => :unsupported_capability,
    "unsupported_tool" => :unsupported_capability,
    "unsupported_value" => :unsupported_capability,
    "unsupported_model" => :unsupported_model,
    "model_not_found" => :unsupported_model,
    "server_error" => :provider_error,
    "temporarily_unavailable" => :temporarily_unavailable
  }
  @reauth [
    :invalid_grant,
    :invalid_token,
    :invalid_refresh_token,
    :refresh_token_reused,
    :token_revoked,
    :token_expired,
    :refresh_token_expired,
    :refresh_token_invalidated,
    :reauth_required,
    :chatpass_v2_invalid_authorization_context
  ]

  @doc "Builds a diagnostic from machine code and safe, bounded metadata only."
  @spec new(atom(), map() | keyword()) :: t()
  def new(code, attrs \\ %{}) do
    attrs = Map.new(attrs)
    code = if is_atom(code), do: code, else: :provider_error
    status = Map.get(attrs, :status)
    provider = Map.get(attrs, :provider, :openai)

    %__MODULE__{
      code: code,
      provider: if(is_atom(provider), do: provider, else: :openai),
      status: if(is_integer(status) and status in 100..599, do: status),
      request_id: request_id(Map.get(attrs, :request_id)),
      retry_after: nonnegative_integer(Map.get(attrs, :retry_after)),
      eligibility: eligibility(Map.get(attrs, :eligibility), code),
      quota: quota(Map.get(attrs, :quota)),
      retryable: Map.get(attrs, :retryable) == true,
      reauth_required: Map.get(attrs, :reauth_required) == true or code in @reauth
    }
  end

  @doc "Classifies an HTTP or statusless streamed failure without retaining payloads."
  @spec from_response(integer() | nil, term(), map() | list()) :: t()
  def from_response(status, body, headers \\ %{}) do
    code = body |> provider_code() |> then(&Map.get(@codes, &1, default_code(status)))

    new(code, %{
      status: status,
      request_id: header(headers, "openai-request-id") || header(headers, "x-request-id"),
      retry_after:
        retry_after(header(headers, "retry-after") || error_field(body, "retry_after")),
      eligibility: error_field(body, "eligibility"),
      quota: error_field(body, "quota"),
      retryable:
        code in [
          :temporarily_unavailable,
          :subscription_sharing_usage_unavailable,
          :subscription_sharing_user_unavailable
        ] or
          (status == 429 and
             code not in [:usage_limit, :subscription_sharing_usage_limit_exceeded]) or
          status in 500..599,
      reauth_required: code in @reauth
    })
  end

  @doc "Drops arbitrary exception metadata at the broker boundary."
  @spec safe(term()) :: t()
  def safe(%__MODULE__{} = error), do: new(error.code, Map.from_struct(error))
  def safe(_error), do: new(:provider_error)

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{reauth_required: terminal}), do: terminal

  @impl Exception
  def message(%__MODULE__{code: code, status: nil}), do: "authentication failed: #{code}"

  def message(%__MODULE__{code: code, status: status}),
    do: "authentication failed: #{code} (HTTP #{status})"

  defp provider_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp provider_code(%{"error" => code}) when is_binary(code), do: code
  defp provider_code(%{"code" => code}) when is_binary(code), do: code
  defp provider_code(%{error: %{code: code}}) when is_binary(code), do: code
  defp provider_code(_body), do: nil

  defp error_field(%{"error" => error}, field) when is_map(error), do: Map.get(error, field)
  defp error_field(body, field) when is_map(body), do: Map.get(body, field)
  defp error_field(_body, _field), do: nil

  defp retry_after(value) when is_binary(value) and byte_size(value) <= 12 do
    case Integer.parse(value) do
      {seconds, ""} -> nonnegative_integer(seconds)
      _invalid -> nil
    end
  end

  defp retry_after(value), do: nonnegative_integer(value)
  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: nil

  defp eligibility(value, _code) when value in [:eligible, :ineligible, :admission_required],
    do: value

  defp eligibility("eligible", _code), do: :eligible
  defp eligibility("ineligible", _code), do: :ineligible
  defp eligibility("admission_required", _code), do: :admission_required

  defp eligibility(_value, code)
       when code in [:ineligible, :subscription_sharing_user_not_eligible], do: :ineligible

  defp eligibility(_value, :admission_denied), do: :admission_required
  defp eligibility(_value, _code), do: nil

  defp quota(value) when is_map(value) do
    result =
      Enum.reduce([:limit, :remaining, :used, :reset_at, :window_seconds], %{}, fn key, acc ->
        case nonnegative_integer(Map.get(value, key, Map.get(value, Atom.to_string(key)))) do
          nil -> acc
          count -> Map.put(acc, key, count)
        end
      end)

    if map_size(result) > 0, do: result
  end

  defp quota(_value), do: nil

  defp default_code(401), do: :invalid_token
  defp default_code(403), do: :access_denied
  defp default_code(429), do: :rate_limited
  defp default_code(_status), do: :provider_error

  defp header(headers, name) when is_map(headers), do: headers |> Map.get(name) |> first_header()

  defp header(headers, name) when is_list(headers),
    do: headers |> List.keyfind(name, 0) |> first_header()

  defp header(_headers, _name), do: nil
  defp first_header({_name, value}), do: first_header(value)
  defp first_header([value | _rest]), do: value
  defp first_header(value), do: value

  defp request_id(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value), do: value
  end

  defp request_id(_value), do: nil
end
