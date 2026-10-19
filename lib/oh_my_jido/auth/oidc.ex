defmodule OhMyJido.Auth.OIDC do
  @moduledoc """
  OpenAI discovery and strict RS256 ID-token verification for SIWC public clients.

  Only issuer-published RSA signing keys are accepted. JWT headers never select
  remote keys, an algorithm family, or a different issuer. HTTP injection is
  limited to Req adapters and connection options; it cannot change the protocol
  endpoints or enable redirects. No credentials are decoded without verification.
  """

  alias OhMyJido.Auth.Error

  @issuer "https://auth.openai.com"
  @discovery_url @issuer <> "/.well-known/openid-configuration"
  @req_injection_keys [
    :adapter,
    :plug,
    :receive_timeout,
    :connect_options,
    :finch,
    :finch_options,
    :pool_timeout
  ]
  @max_token_bytes 65_536

  @spec issuer() :: String.t()
  def issuer, do: @issuer

  @spec discover(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def discover(opts \\ []) do
    with {:ok, response} <- request(:get, @discovery_url, nil, opts) do
      discovery_metadata(response.body)
    end
  end

  @spec jwks(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def jwks(metadata, opts \\ []) do
    with true <- metadata[:issuer] == @issuer and trusted_endpoint?(metadata[:jwks_uri]),
         {:ok, response} <- request(:get, metadata.jwks_uri, nil, opts),
         %{"keys" => keys} = body <- response.body,
         true <- is_list(keys) and length(keys) in 1..128 do
      {:ok, body}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:oidc_jwks_invalid)
    end
  end

  @doc false
  @spec request(atom(), String.t(), keyword() | nil, keyword()) ::
          {:ok, Req.Response.t()} | {:error, Error.t()}
  def request(method, url, form, opts) do
    injection = opts |> Keyword.get(:req_options, []) |> Keyword.take(@req_injection_keys)

    request_opts =
      injection
      |> Keyword.merge(
        method: method,
        url: url,
        headers: [{"accept", "application/json"}],
        retry: false,
        redirect: false
      )
      |> Keyword.put_new(:receive_timeout, 15_000)

    request_opts = if form == nil, do: request_opts, else: Keyword.put(request_opts, :form, form)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{} = response} ->
        {:error, Error.from_response(response.status, response.body, response.headers)}

      {:error, _reason} ->
        failure(:provider_unavailable, %{retryable: true})
    end
  rescue
    _ -> failure(:provider_unavailable, %{retryable: true})
  end

  @spec verify(term(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify(token, jwks, opts) do
    with {:ok, header, claims, signed, signature} <- decode_token(token),
         :ok <- validate_header(header),
         {:ok, key} <- signing_key(jwks, header),
         :ok <- verify_signature(signed, signature, key),
         :ok <- validate_claims(claims, opts) do
      {:ok, claims}
    end
  rescue
    _ -> failure(:oidc_token_invalid)
  end

  defp discovery_metadata(body) when is_map(body) do
    supported = body["id_token_signing_alg_values_supported"]

    cond do
      body["issuer"] != @issuer ->
        failure(:oidc_issuer_mismatch)

      not is_list(supported) or "RS256" not in supported ->
        failure(:oidc_algorithm_unsupported)

      body["authorization_endpoint"] != @issuer <> "/api/accounts/authorize" or
        body["token_endpoint"] != @issuer <> "/api/accounts/oauth/token" or
        not trusted_endpoint?(body["jwks_uri"]) or
          not optional_endpoint?(body["revocation_endpoint"]) ->
        failure(:openid_configuration_invalid)

      true ->
        {:ok,
         %{
           issuer: @issuer,
           authorization_endpoint: body["authorization_endpoint"],
           token_endpoint: body["token_endpoint"],
           jwks_uri: body["jwks_uri"],
           revocation_endpoint: body["revocation_endpoint"]
         }}
    end
  end

  defp discovery_metadata(_), do: failure(:openid_configuration_invalid)
  defp optional_endpoint?(nil), do: true
  defp optional_endpoint?(url), do: trusted_endpoint?(url)

  defp trusted_endpoint?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: "auth.openai.com",
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(path) and path != "" ->
        true

      _ ->
        false
    end
  end

  defp trusted_endpoint?(_), do: false

  defp decode_token(token) when is_binary(token) and byte_size(token) in 1..@max_token_bytes do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         {:ok, header_bytes} <- decode_segment(encoded_header),
         {:ok, claims_bytes} <- decode_segment(encoded_claims),
         {:ok, signature} <- decode_segment(encoded_signature),
         {:ok, header} <- decode_object(header_bytes),
         {:ok, claims} <- decode_object(claims_bytes) do
      {:ok, header, claims, encoded_header <> "." <> encoded_claims, signature}
    else
      _ -> failure(:oidc_token_invalid)
    end
  end

  defp decode_token(_), do: failure(:oidc_token_invalid)

  defp decode_segment(value) when is_binary(value) and value != "" do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(decoded, padding: false) == value do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp decode_segment(_), do: :error

  defp decode_object(bytes) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         keys = Enum.map(values, &elem(&1, 0)),
         true <- length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, Map.new(values)}
    else
      _ -> :error
    end
  end

  defp validate_header(%{"alg" => "RS256", "kid" => kid} = header)
       when is_binary(kid) and byte_size(kid) in 1..256 do
    if Map.get(header, "typ", "JWT") == "JWT" and
         Map.get(header, "crit", []) == [] and
         not Enum.any?(["jku", "jwk", "x5u", "b64"], &Map.has_key?(header, &1)) do
      :ok
    else
      failure(:oidc_token_invalid)
    end
  end

  defp validate_header(%{"alg" => "RS256"}), do: failure(:oidc_key_invalid)
  defp validate_header(_), do: failure(:oidc_algorithm_unsupported)

  defp signing_key(%{"keys" => keys}, header) when is_list(keys) and length(keys) in 1..128 do
    matches = Enum.filter(keys, &(is_map(&1) and &1["kid"] == header["kid"]))

    with [key] <- matches,
         true <- key["kty"] == "RSA" and Map.get(key, "alg", "RS256") == "RS256",
         true <- Map.get(key, "use", "sig") == "sig",
         true <- valid_key_operations?(Map.get(key, "key_ops")),
         {:ok, modulus} <- decode_segment(key["n"]),
         {:ok, exponent} <- decode_segment(key["e"]),
         true <- byte_size(modulus) in 256..1024 and byte_size(exponent) in 1..8,
         true <- :binary.first(modulus) >= 128,
         exponent_value = :binary.decode_unsigned(exponent),
         true <- exponent_value >= 3 and rem(exponent_value, 2) == 1 do
      {:ok, [exponent, modulus]}
    else
      _ -> failure(:oidc_key_invalid)
    end
  end

  defp signing_key(_, _), do: failure(:oidc_key_invalid)
  defp valid_key_operations?(nil), do: true
  defp valid_key_operations?(operations) when is_list(operations), do: "verify" in operations
  defp valid_key_operations?(_), do: false

  defp verify_signature(signed, signature, [_, modulus] = key) do
    if byte_size(signature) == byte_size(modulus) and
         :crypto.verify(:rsa, :sha256, signed, signature, key, rsa_padding: :rsa_pkcs1_padding) do
      :ok
    else
      failure(:oidc_signature_invalid)
    end
  rescue
    _ -> failure(:oidc_signature_invalid)
  end

  defp validate_claims(claims, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- validate_claims_identity(claims, opts),
         :ok <- validate_claims_time(claims, now) do
      validate_claims_binding(claims, opts)
    end
  end

  defp validate_claims_identity(claims, opts) do
    cond do
      Keyword.get(opts, :issuer) != @issuer or claims["iss"] != @issuer ->
        failure(:oidc_issuer_mismatch)

      not audience_matches?(claims, Keyword.get(opts, :client_id)) ->
        failure(:oidc_audience_mismatch)

      true ->
        :ok
    end
  end

  defp validate_claims_time(claims, now) do
    tolerance = 5

    cond do
      not valid_claim_values?(claims, now, tolerance) or
          not valid_not_before?(claims["nbf"], now, tolerance) ->
        failure(:oidc_claims_invalid)

      claims["exp"] <= now - tolerance ->
        failure(:oidc_token_expired)

      true ->
        :ok
    end
  end

  defp valid_claim_values?(claims, now, tolerance) do
    subject = claims["sub"]
    expires = claims["exp"]
    issued = claims["iat"]

    is_binary(subject) and subject != "" and is_integer(expires) and is_integer(issued) and
      issued <= now + tolerance and issued < expires
  end

  defp valid_not_before?(nil, _now, _tolerance), do: true

  defp valid_not_before?(value, now, tolerance),
    do: is_integer(value) and value <= now + tolerance

  defp validate_claims_binding(claims, opts) do
    cond do
      Keyword.get(opts, :nonce) != nil and
          not secure_equal?(claims["nonce"], Keyword.get(opts, :nonce)) ->
        failure(:oidc_nonce_mismatch)

      Keyword.get(opts, :subject) != nil and claims["sub"] != Keyword.get(opts, :subject) ->
        failure(:oidc_subject_mismatch)

      true ->
        :ok
    end
  end

  defp audience_matches?(claims, client) when is_binary(client) and client != "" do
    case claims["aud"] do
      ^client ->
        Map.get(claims, "azp", client) == client

      audiences when is_list(audiences) ->
        audience_list_matches?(audiences, claims, client)

      _ ->
        false
    end
  end

  defp audience_matches?(_, _), do: false

  defp audience_list_matches?([audience], claims, client) do
    is_binary(audience) and audience == client and Map.get(claims, "azp", client) == client
  end

  defp audience_list_matches?([_, _ | _] = audiences, claims, client) do
    Enum.all?(audiences, &is_binary/1) and client in audiences and claims["azp"] == client
  end

  defp audience_list_matches?(_, _, _), do: false

  @doc false
  @spec secure_equal?(term(), term()) :: boolean()
  def secure_equal?(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
      do: :crypto.hash_equals(left, right)

  def secure_equal?(_, _), do: false
  defp failure(code, attrs \\ %{}), do: {:error, Error.new(code, attrs)}
end
