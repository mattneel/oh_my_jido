defmodule OhMyJido.Auth.OpenAI do
  @moduledoc """
  Human-initiated Sign in with ChatGPT for third-party open-source/local hosts.

  Registration uses the documented dynamic entrypoint, not an official client's
  identity. The host starts its loopback listener first, stores the returned
  attempt privately, and consumes that attempt once through the account broker.
  Returning sign-in, refresh, and revocation retain the issued client and host
  bindings. This module performs only authentication HTTP, never inference.
  """

  alias OhMyJido.Auth.{Error, OIDC}

  @dynamic_client "dynamic_agent_client"
  @resource "https://api.openai.com/v1"
  @scopes ~w(openid profile email offline_access resource.invoke chatgpt.tokens.use.direct)
  @scope_pattern ~r/\A[\x21\x23-\x5B\x5D-\x7E]+(?: [\x21\x23-\x5B\x5D-\x7E]+)*\z/
  @pkce_pattern ~r/\A[A-Za-z0-9._~-]{43,128}\z/
  @client_pattern ~r/\A[\x21-\x7E]+\z/
  @bearer_pattern ~r/\A[A-Za-z0-9._~+\/-]+=*\z/

  @spec begin_login(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def begin_login(opts) do
    account = Keyword.get(opts, :account)
    redirect = Keyword.get(opts, :redirect_uri)
    host = Keyword.get(opts, :host_id)
    app_name = Keyword.get(opts, :app_name)

    with :ok <- require_value(app_name, :app_name_missing),
         :ok <- require_value(host, :host_id_missing),
         :ok <- validate_redirect(redirect),
         :ok <- returning_binding(account, host, redirect),
         {:ok, discovery} <- OIDC.discover(opts) do
      state = random_value(32)
      nonce = random_value(32)
      verifier = random_value(64)
      challenge = pkce_challenge(verifier)
      client = if account == nil, do: @dynamic_client, else: account.client_id

      params = [
        client_id: client,
        ext_agent_host_id: host,
        response_type: "code",
        redirect_uri: redirect,
        scope: Enum.join(@scopes, " "),
        resource: @resource,
        state: state,
        nonce: nonce,
        code_challenge_method: "S256",
        code_challenge: challenge
      ]

      params = authorization_hints(params, account, app_name)

      params =
        if Keyword.get(opts, :consent, false) == true,
          do: Keyword.put(params, :prompt, "consent"),
          else: params

      {:ok,
       %{
         authorization_url: discovery.authorization_endpoint <> "?" <> URI.encode_query(params),
         state: state,
         nonce: nonce,
         verifier: verifier,
         code_challenge: challenge,
         redirect_uri: redirect,
         expires_at: now(opts) + 600,
         host_id: host,
         client_id: client,
         issuer: discovery.issuer,
         subject: if(account == nil, do: nil, else: account.subject)
       }}
    end
  end

  @spec complete_login(map(), String.t() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def complete_login(attempt, callback, opts \\ []) do
    with :ok <- validate_attempt(attempt, opts),
         {:ok, params} <- callback_params(callback, attempt.redirect_uri),
         :ok <- validate_state(params["state"], attempt.state),
         :ok <- callback_error(params),
         :ok <- callback_issuer(params),
         {:ok, client} <- callback_client(params["client_id"], attempt.client_id),
         :ok <- require_value(params["code"], :authorization_code_missing),
         {:ok, discovery} <- OIDC.discover(opts),
         {:ok, response} <-
           OIDC.request(
             :post,
             discovery.token_endpoint,
             [
               grant_type: "authorization_code",
               client_id: client,
               code: params["code"],
               code_verifier: attempt.verifier,
               redirect_uri: attempt.redirect_uri,
               resource: @resource
             ],
             opts
           ),
         {:ok, tokens} <- token_values(response.body, nil, opts),
         :ok <- require_value(tokens.id_token, :id_token_missing),
         {:ok, jwks} <- OIDC.jwks(discovery, opts),
         {:ok, identity} <-
           OIDC.verify(tokens.id_token, jwks,
             issuer: discovery.issuer,
             client_id: client,
             nonce: attempt.nonce,
             subject: Map.get(attempt, :subject),
             now: now(opts)
           ) do
      record = %{
        provider: :openai,
        access_mode: :subscription,
        client_id: client,
        host_id: attempt.host_id,
        issuer: identity["iss"],
        subject: identity["sub"],
        redirect_uri: attempt.redirect_uri
      }

      record =
        if is_binary(identity["email"]),
          do: Map.put(record, :email, identity["email"]),
          else: record

      {:ok, Map.merge(record, tokens)}
    end
  end

  @spec refresh(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def refresh(record, opts \\ []) do
    with :ok <- record_binding(record, Keyword.get(opts, :host_id)),
         :ok <- require_value(Map.get(record, :refresh_token), :refresh_token_missing),
         {:ok, discovery} <- OIDC.discover(opts),
         {:ok, response} <-
           OIDC.request(
             :post,
             discovery.token_endpoint,
             [
               grant_type: "refresh_token",
               client_id: record.client_id,
               refresh_token: record.refresh_token,
               resource: @resource
             ],
             opts
           ),
         {:ok, tokens} <- token_values(response.body, record, opts),
         :ok <- validate_refreshed_identity(response.body, record, discovery, opts) do
      {:ok, Map.merge(record, tokens)}
    end
  end

  @spec revoke(map(), keyword()) :: :ok | {:error, Error.t()}
  def revoke(record, opts \\ []) do
    with :ok <- record_binding(record, Keyword.get(opts, :host_id)),
         :ok <- require_value(Map.get(record, :refresh_token), :refresh_token_missing),
         {:ok, discovery} <- OIDC.discover(opts),
         :ok <- require_value(discovery.revocation_endpoint, :revocation_unavailable),
         {:ok, response} <-
           OIDC.request(
             :post,
             discovery.revocation_endpoint,
             [
               token: record.refresh_token,
               token_type_hint: "refresh_token",
               client_id: record.client_id
             ],
             opts
           ) do
      if response.status == 200,
        do: :ok,
        else: failure(:revocation_unconfirmed, %{status: response.status})
    end
  end

  defp validate_attempt(attempt, opts) when is_map(attempt) do
    with :ok <- validate_attempt_binding(attempt, opts),
         :ok <- validate_attempt_proof(attempt) do
      if attempt[:client_id] == @dynamic_client or issued_client?(attempt[:client_id]),
        do: validate_redirect(attempt[:redirect_uri]),
        else: failure(:client_id_invalid)
    end
  end

  defp validate_attempt(_, _), do: failure(:attempt_invalid)

  defp validate_attempt_binding(attempt, opts) do
    cond do
      not is_integer(attempt[:expires_at]) or attempt[:expires_at] <= now(opts) ->
        failure(:attempt_expired)

      not valid_value?(attempt[:host_id]) or
          Keyword.get(opts, :host_id, attempt[:host_id]) != attempt[:host_id] ->
        failure(:host_binding_mismatch)

      attempt[:issuer] != OIDC.issuer() ->
        failure(:oidc_issuer_mismatch)

      true ->
        :ok
    end
  end

  defp validate_attempt_proof(attempt) do
    cond do
      not valid_value?(attempt[:state]) or not valid_value?(attempt[:nonce]) ->
        failure(:attempt_invalid)

      not is_binary(attempt[:verifier]) or not Regex.match?(@pkce_pattern, attempt[:verifier]) or
          not OIDC.secure_equal?(pkce_challenge(attempt[:verifier]), attempt[:code_challenge]) ->
        failure(:pkce_invalid)

      true ->
        :ok
    end
  end

  defp returning_binding(nil, _, _), do: :ok

  defp returning_binding(account, host, redirect) when is_map(account) do
    with :ok <- record_binding(account, host),
         :ok <- validate_redirect(account[:redirect_uri]),
         true <- redirect_registration(redirect) == redirect_registration(account.redirect_uri) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:redirect_mismatch)
    end
  end

  defp returning_binding(_, _, _), do: failure(:account_invalid)

  defp record_binding(record, host) when is_map(record) do
    with :ok <- record_host_binding(record, host) do
      record_identity_binding(record)
    end
  end

  defp record_binding(_, _), do: failure(:account_invalid)

  defp record_host_binding(record, host) do
    if not valid_value?(host) or not valid_value?(record[:host_id]) or record[:host_id] != host,
      do: failure(:host_binding_mismatch),
      else: :ok
  end

  defp record_identity_binding(record) do
    cond do
      record[:provider] != :openai or record[:access_mode] != :subscription ->
        failure(:account_invalid)

      not issued_client?(record[:client_id]) ->
        failure(:client_id_invalid)

      record[:issuer] != OIDC.issuer() ->
        failure(:oidc_issuer_mismatch)

      not valid_value?(record[:subject]) ->
        failure(:account_invalid)

      true ->
        :ok
    end
  end

  defp validate_redirect(redirect) when is_binary(redirect) do
    case URI.parse(redirect) do
      %URI{
        scheme: "http",
        host: "127.0.0.1",
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_integer(port) and port in 1..65_535 and is_binary(path) and path != "" ->
        :ok

      _ ->
        failure(:redirect_uri_invalid)
    end
  end

  defp validate_redirect(_), do: failure(:redirect_uri_invalid)

  defp redirect_registration(redirect) do
    uri = URI.parse(redirect)
    {uri.scheme, uri.host, uri.path}
  end

  defp authorization_hints(params, nil, app_name),
    do: Keyword.put(params, :agent_name_hint, app_name)

  defp authorization_hints(params, account, _app_name) do
    params
    |> put_hint(:id_token_hint, account[:id_token])
    |> put_hint(:login_hint, account[:email])
  end

  defp put_hint(params, key, value) do
    if valid_value?(value), do: Keyword.put(params, key, value), else: params
  end

  defp callback_params(callback, redirect) when is_binary(callback) do
    case String.split(callback, "?", parts: 2) do
      [^redirect, query] ->
        if String.contains?(query, "#"),
          do: failure(:callback_invalid),
          else: decode_callback_query(query)

      _ ->
        failure(:redirect_mismatch)
    end
  end

  defp callback_params(callback, redirect) when is_map(callback) do
    with {:ok, params} <- normalize_callback_map(callback),
         true <- params["redirect_uri"] == redirect do
      {:ok, Map.delete(params, "redirect_uri")}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:callback_invalid)
    end
  end

  defp callback_params(_, _), do: failure(:callback_invalid)

  defp decode_callback_query(query) do
    pairs = query |> URI.query_decoder() |> Enum.to_list()
    unique_callback_pairs(pairs)
  rescue
    _ -> failure(:callback_invalid)
  end

  defp normalize_callback_map(callback) do
    pairs =
      Enum.map(callback, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)

    unique_callback_pairs(pairs)
  end

  defp unique_callback_pairs(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if Enum.all?(pairs, fn {key, value} -> is_binary(key) and is_binary(value) end) and
         length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, Map.new(pairs)}
    else
      failure(:callback_invalid)
    end
  end

  defp validate_state(returned, expected) do
    if OIDC.secure_equal?(returned, expected), do: :ok, else: failure(:state_mismatch)
  end

  defp callback_error(%{"error" => "access_denied"}), do: failure(:access_denied)
  defp callback_error(%{"error" => _}), do: failure(:authorization_failed)
  defp callback_error(_), do: :ok

  defp callback_issuer(%{"iss" => issuer}) do
    if issuer == OIDC.issuer(), do: :ok, else: failure(:oidc_issuer_mismatch)
  end

  defp callback_issuer(_), do: :ok

  defp callback_client(client, @dynamic_client) do
    if issued_client?(client), do: {:ok, client}, else: failure(:client_id_invalid)
  end

  defp callback_client(nil, expected), do: {:ok, expected}
  defp callback_client(client, client), do: {:ok, client}
  defp callback_client(_, _), do: failure(:client_id_mismatch)

  defp token_values(body, previous, opts) when is_map(body) do
    refresh = Map.get(body, "refresh_token")
    identity = Map.get(body, "id_token", if(previous, do: previous[:id_token]))

    granted_scope =
      Map.get(body, "scope", if(previous, do: Enum.join(previous[:scopes] || [], " ")))

    with :ok <- require_bearer(body["access_token"]),
         :ok <- require_value(refresh, :refresh_token_missing),
         true <- body["token_type"] in ["Bearer", "bearer"],
         true <- is_integer(body["expires_in"]) and body["expires_in"] > 0,
         {:ok, scopes} <- parse_scopes(granted_scope) do
      {:ok,
       %{
         access_token: body["access_token"],
         refresh_token: refresh,
         id_token: identity,
         scopes: scopes,
         expires_at: now(opts) + body["expires_in"],
         status:
           if("chatgpt.tokens.use.direct" in scopes and "resource.invoke" in scopes,
             do: :active,
             else: :consent_required
           )
       }}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:token_response_invalid)
    end
  end

  defp token_values(_, _, _), do: failure(:token_response_invalid)

  defp parse_scopes(scope) when is_binary(scope) do
    if Regex.match?(@scope_pattern, scope) do
      scopes = scope |> String.split(" ") |> Enum.uniq()
      if "openid" in scopes, do: {:ok, scopes}, else: failure(:scope_invalid)
    else
      failure(:scope_invalid)
    end
  end

  defp parse_scopes(_), do: failure(:scope_invalid)

  defp validate_refreshed_identity(%{"id_token" => token}, record, discovery, opts) do
    with :ok <- require_value(token, :id_token_missing),
         {:ok, jwks} <- OIDC.jwks(discovery, opts),
         {:ok, _identity} <-
           OIDC.verify(token, jwks,
             issuer: record.issuer,
             client_id: record.client_id,
             subject: record.subject,
             now: now(opts)
           ) do
      :ok
    end
  end

  defp validate_refreshed_identity(_, _, _, _), do: :ok

  defp issued_client?(value),
    do:
      is_binary(value) and value != @dynamic_client and byte_size(value) <= 256 and
        Regex.match?(@client_pattern, value)

  defp valid_bearer?(value),
    do:
      is_binary(value) and byte_size(value) in 1..65_536 and Regex.match?(@bearer_pattern, value)

  defp require_bearer(value),
    do: if(valid_bearer?(value), do: :ok, else: failure(:access_token_missing))

  defp random_value(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp pkce_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp now(opts), do: Keyword.get(opts, :now, System.system_time(:second))

  defp valid_value?(value),
    do: is_binary(value) and byte_size(value) in 1..65_536 and String.trim(value) != ""

  defp require_value(value, code) do
    if valid_value?(value), do: :ok, else: failure(code)
  end

  defp failure(code, attrs \\ %{}), do: {:error, Error.new(code, attrs)}
end
