defmodule OhMyJido.Auth.OpenAITest do
  use ExUnit.Case, async: true

  alias OhMyJido.Auth
  alias OhMyJido.Auth.{Broker, Error, FileStore, OpenAI}

  @now 1_800_000_000
  @issuer "https://auth.openai.com"
  @redirect "http://127.0.0.1:49152/auth/callback"
  @client "oaiapp_issued_fixture"
  @host "urn:uuid:7e7d8484-79f5-467a-8543-5367e45de870"
  @scopes "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

  setup_all do
    {[exponent, modulus], private} = :crypto.generate_key(:rsa, {2048, 65_537})

    jwks = %{
      "keys" => [
        %{
          "kty" => "RSA",
          "kid" => "test-key",
          "alg" => "RS256",
          "use" => "sig",
          "n" => encode_bytes(modulus),
          "e" => encode_bytes(exponent)
        }
      ]
    }

    %{private: private, jwks: jwks}
  end

  test "dynamic registration uses fresh state, nonce and S256 PKCE with actual host and app" do
    {:ok, first} = begin()
    {:ok, second} = begin()
    query = first.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == "dynamic_agent_client"
    assert query["agent_name_hint"] == "Oh-My-Jido test host"
    assert query["ext_agent_host_id"] == "host-one"
    assert query["scope"] == @scopes
    assert query["resource"] == "https://api.openai.com/v1"
    assert query["redirect_uri"] == @redirect
    assert query["code_challenge_method"] == "S256"
    assert query["code_challenge"] == encode_bytes(:crypto.hash(:sha256, first.verifier))
    assert first.state != second.state
    assert first.nonce != second.nonce
    assert first.verifier != second.verifier
    assert byte_size(first.verifier) >= 43
    assert first.expires_at > @now
  end

  test "loopback redirect cannot use localhost, query, fragment or alternate host" do
    for redirect <- [
          "http://localhost:49152/auth/callback",
          "https://127.0.0.1/auth/callback",
          "http://127.0.0.2:49152/auth/callback",
          @redirect <> "?next=x",
          @redirect <> "#fragment"
        ] do
      assert {:error, %Error{code: :redirect_uri_invalid}} = begin(redirect_uri: redirect)
    end
  end

  test "state, expiry, host, exact redirect and duplicate callback parameters fail before exchange" do
    {:ok, attempt} = begin()

    no_exchange = [
      req_options: [plug: fn _ -> flunk("invalid callback must not perform HTTP") end],
      now: @now
    ]

    for {callback, code} <- [
          {callback(attempt, state: "wrong"), :state_mismatch},
          {String.replace(callback(attempt), ":49152/", ":49153/"), :redirect_mismatch},
          {String.replace(callback(attempt), "/auth/callback", "/callback"), :redirect_mismatch},
          {callback(attempt) <> "&state=" <> attempt.state, :callback_invalid},
          {callback(attempt, client_id: "dynamic_agent_client"), :client_id_invalid}
        ] do
      assert {:error, %Error{code: ^code}} = OpenAI.complete_login(attempt, callback, no_exchange)
    end

    assert {:error, %Error{code: :attempt_expired}} =
             OpenAI.complete_login(%{attempt | expires_at: @now}, callback(attempt), no_exchange)

    assert {:error, %Error{code: :host_binding_mismatch}} =
             OpenAI.complete_login(
               attempt,
               callback(attempt),
               Keyword.put(no_exchange, :host_id, "host-two")
             )

    assert {:error, %Error{code: :pkce_invalid}} =
             OpenAI.complete_login(%{attempt | verifier: "short"}, callback(attempt), no_exchange)

    assert {:error, %Error{code: :callback_invalid}} =
             OpenAI.complete_login(
               attempt,
               %{state: attempt.state, code: "code", client_id: @client},
               no_exchange
             )
  end

  test "denied consent validates state and never redeems a code" do
    {:ok, attempt} = begin()

    opts = [
      now: @now,
      req_options: [plug: fn _ -> flunk("consent denial must not exchange") end]
    ]

    denied =
      @redirect <>
        "?" <> URI.encode_query(%{"state" => attempt.state, "error" => "access_denied"})

    assert {:error, %Error{code: :access_denied}} = OpenAI.complete_login(attempt, denied, opts)

    assert {:error, %Error{code: :state_mismatch}} =
             OpenAI.complete_login(attempt, String.replace(denied, attempt.state, "wrong"), opts)
  end

  test "exchanges issued ID and exact verifier then commits only validated identity", fixture do
    {:ok, attempt} = begin()
    parent = self()
    plug = fixture_plug(fixture, token_response(fixture, attempt.nonce), parent)

    assert {:ok, record} =
             OpenAI.complete_login(attempt, callback(attempt),
               now: @now,
               req_options: [plug: plug]
             )

    assert record.client_id == @client
    assert record.host_id == "host-one"
    assert record.subject == "verified-account"
    assert record.issuer == @issuer
    assert record.status == :active
    assert record.access_mode == :subscription
    assert record.expires_at == @now + 3600
    assert record.redirect_uri == @redirect
    assert_receive {:token_request, form}
    assert form["grant_type"] == "authorization_code"
    assert form["client_id"] == @client
    assert form["code_verifier"] == attempt.verifier
    assert form["redirect_uri"] == @redirect
    assert form["resource"] == "https://api.openai.com/v1"
    refute Map.has_key?(form, "client_secret")
  end

  test "issued client identifiers are opaque and bound by the verified audience", fixture do
    {:ok, attempt} = begin()
    issued = "issued-registration-local"
    tokens = token_response(fixture, attempt.nonce, %{"aud" => issued})
    plug = fixture_plug(fixture, tokens, self())

    assert {:ok, %{client_id: ^issued}} =
             OpenAI.complete_login(attempt, callback(attempt, client_id: issued),
               now: @now,
               req_options: [plug: plug]
             )
  end

  test "malformed bearer, token type, access expiry and missing identity fail closed", fixture do
    {:ok, attempt} = begin()
    valid = token_response(fixture, attempt.nonce)

    for {tokens, code} <- [
          {Map.put(valid, "access_token", "token\r\ninjected"), :access_token_missing},
          {Map.put(valid, "token_type", "Basic"), :token_response_invalid},
          {Map.put(valid, "expires_in", 0), :token_response_invalid},
          {Map.delete(valid, "id_token"), :id_token_missing},
          {Map.put(valid, "scope", "email profile"), :scope_invalid}
        ] do
      plug = fixture_plug(fixture, tokens, self())

      assert {:error, %Error{code: ^code}} =
               OpenAI.complete_login(attempt, callback(attempt),
                 now: @now,
                 req_options: [plug: plug]
               )
    end
  end

  test "ID-token nonce and signature failures cannot commit credentials", fixture do
    {:ok, attempt} = begin()

    for {tokens, code} <- [
          {token_response(fixture, "another-nonce"), :oidc_nonce_mismatch},
          {Map.put(
             token_response(fixture, attempt.nonce),
             "id_token",
             forged_token(fixture, attempt.nonce)
           ), :oidc_signature_invalid}
        ] do
      plug = fixture_plug(fixture, tokens, self())

      assert {:error, %Error{code: ^code}} =
               OpenAI.complete_login(attempt, callback(attempt),
                 now: @now,
                 req_options: [plug: plug]
               )
    end
  end

  test "token scopes, not callback scopes, control plan consent", fixture do
    {:ok, attempt} = begin()

    tokens =
      Map.put(
        token_response(fixture, attempt.nonce),
        "scope",
        "openid profile email offline_access"
      )

    plug = fixture_plug(fixture, tokens, self())

    assert {:ok, %{status: :consent_required, scopes: scopes}} =
             OpenAI.complete_login(attempt, callback(attempt),
               now: @now,
               req_options: [plug: plug]
             )

    refute "chatgpt.tokens.use.direct" in scopes

    for invalid <- [nil, ["openid"], "openid\nchatgpt.tokens.use.direct"] do
      plug = fixture_plug(fixture, Map.put(tokens, "scope", invalid), self())

      assert {:error, %Error{code: :scope_invalid}} =
               OpenAI.complete_login(attempt, callback(attempt),
                 now: @now,
                 req_options: [plug: plug]
               )
    end
  end

  test "returning registration retains client and host, validates subject and allows only port changes",
       fixture do
    account = record()

    assert {:ok, attempt} =
             begin(account: account, redirect_uri: "http://127.0.0.1:50000/auth/callback")

    query = attempt.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == @client
    assert query["id_token_hint"] == account.id_token
    refute Map.has_key?(query, "agent_name_hint")
    refute Map.has_key?(query, "prompt")

    assert {:error, %Error{code: :host_binding_mismatch}} =
             begin(account: account, host_id: "host-two")

    assert {:error, %Error{code: :redirect_mismatch}} =
             begin(account: account, redirect_uri: "http://127.0.0.1:50000/callback")

    assert {:error, %Error{code: :client_id_mismatch}} =
             OpenAI.complete_login(attempt, callback(attempt, client_id: "oaiapp_other"),
               now: @now
             )

    tokens = token_response(fixture, attempt.nonce, %{"sub" => "another-account"})
    plug = fixture_plug(fixture, tokens, self())

    assert {:error, %Error{code: :oidc_subject_mismatch}} =
             OpenAI.complete_login(attempt, callback(attempt, client_id: nil),
               now: @now,
               req_options: [plug: plug]
             )
  end

  test "explicit consent uses prompt=consent only on requested reauthorization" do
    assert {:ok, attempt} = begin(account: record(), consent: true)
    query = attempt.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["prompt"] == "consent"
    refute Map.has_key?(query, "force_reconsent")
  end

  test "refresh rotates tokens with issued client and resource, and revoke uses discovery",
       fixture do
    tokens =
      token_response(fixture, nil)
      |> Map.delete("id_token")
      |> Map.put("refresh_token", "rotated-refresh")

    plug = fixture_plug(fixture, tokens, self())
    opts = [host_id: "host-one", now: @now, req_options: [plug: plug]]
    assert {:ok, renewed} = OpenAI.refresh(record(), opts)
    assert renewed.refresh_token == "rotated-refresh"
    assert renewed.subject == record().subject
    assert renewed.client_id == @client
    assert_receive {:token_request, form}
    assert form["grant_type"] == "refresh_token"
    assert form["client_id"] == @client
    assert form["resource"] == "https://api.openai.com/v1"
    refute Map.has_key?(form, "scope")
    assert :ok = OpenAI.revoke(renewed, opts)
    assert_receive {:revoke_request, revoked}

    assert revoked == %{
             "client_id" => @client,
             "token" => "rotated-refresh",
             "token_type_hint" => "refresh_token"
           }

    assert {:error, %Error{code: :host_binding_mismatch}} =
             OpenAI.refresh(record(), Keyword.put(opts, :host_id, "another-host"))

    assert {:error, %Error{code: :host_binding_mismatch}} =
             OpenAI.revoke(record(), Keyword.delete(opts, :host_id))
  end

  test "refresh never reports success without the documented replacement refresh token",
       fixture do
    tokens = token_response(fixture, nil) |> Map.delete("id_token") |> Map.delete("refresh_token")
    plug = fixture_plug(fixture, tokens, self())

    assert {:error, %Error{code: :refresh_token_missing}} =
             OpenAI.refresh(record(),
               host_id: "host-one",
               now: @now,
               req_options: [plug: plug]
             )
  end

  test "terminal refresh errors and unconfirmed revocation remain safe errors", fixture do
    for code <- ["invalid_grant", "invalid_refresh_token", "refresh_token_reused"] do
      plug =
        fixture_plug(
          fixture,
          %{status: 400, body: %{"error" => code, "error_description" => "private-token"}},
          self()
        )

      assert {:error, %Error{reauth_required: true, retryable: false} = error} =
               OpenAI.refresh(record(), host_id: "host-one", req_options: [plug: plug])

      refute inspect(error) =~ "private-token"
    end

    plug = fn conn ->
      if conn.request_path == "/.well-known/openid-configuration" do
        Req.Test.json(conn, discovery())
      else
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"detail" => "private-token"})
      end
    end

    assert {:error, %Error{status: 503, retryable: true}} =
             OpenAI.revoke(record(), host_id: "host-one", req_options: [plug: plug])
  end

  describe "broker with the native OpenAI adapter" do
    setup fixture do
      root = Path.join(System.tmp_dir!(), "omj-native-auth-#{System.unique_integer([:positive])}")
      key = :crypto.strong_rand_bytes(32)
      responses = start_supervised!({Agent, fn -> %{} end})
      tasks = start_supervised!(Task.Supervisor)
      store_options = [path: root, key: fn -> key end]

      plug =
        fixture_plug(fixture, fn -> Agent.get(responses, & &1) end, self())

      options = [
        store: {FileStore, store_options},
        task_supervisor: tasks,
        provider: OpenAI,
        provider_options: [now: @now, req_options: [plug: plug]],
        clock: fn -> @now end,
        refresh_before: 60
      ]

      server = start_supervised!({Broker, options})
      assert {:ok, vault} = FileStore.init(store_options)
      on_exit(fn -> File.rm_rf!(root) end)
      %{server: server, options: options, responses: responses, vault: vault}
    end

    @tag :auth_regression
    test "login-only host binding survives recovery, refresh rotation and revocation", fixture do
      account = native_broker_login(fixture)
      reference = account.account_ref
      assert account.status == :active
      assert {:ok, credentials} = Auth.credentials(fixture.server, reference)
      assert credentials[:access_token] == "fixture-access"
      assert {:ok, stored} = FileStore.load(fixture.vault, reference)
      assert stored.host_id == @host
      refute Map.has_key?(stored, :provider_options)
      refute Map.has_key?(stored, :req_options)
      refute Map.has_key?(stored, :callback)

      renewed =
        token_response(fixture, nil)
        |> Map.delete("id_token")
        |> Map.merge(%{
          "access_token" => "native-renewed-access",
          "refresh_token" => "native-rotated-refresh"
        })

      Agent.update(fixture.responses, fn _ -> renewed end)
      server = restart_native_broker(fixture, now: @now + 3_560)

      assert {:ok, credentials} = Auth.credentials(server, reference)
      assert credentials[:access_token] == "native-renewed-access"
      assert_receive {:token_request, refresh}
      assert refresh["grant_type"] == "refresh_token"
      assert refresh["refresh_token"] == "fixture-refresh"
      assert refresh["client_id"] == @client
      assert refresh["resource"] == "https://api.openai.com/v1"
      assert {:ok, [%{account_ref: ^reference, status: :active}]} = Auth.list_accounts(server)
      assert {:ok, stored} = FileStore.load(fixture.vault, reference)
      assert stored.host_id == @host
      assert stored.refresh_token == "native-rotated-refresh"

      assert {:ok, %{local: :logged_out, remote: :revoked}} = Auth.logout(server, reference)
      assert_receive {:revoke_request, revoked}

      assert revoked == %{
               "client_id" => @client,
               "token" => "native-rotated-refresh",
               "token_type_hint" => "refresh_token"
             }

      assert {:error, %Error{code: :logged_out}} = Auth.credentials(server, reference)
      assert {:ok, tombstone} = FileStore.load(fixture.vault, reference)
      assert tombstone.host_id == @host
      refute Map.has_key?(tombstone, :access_token)
      refute Map.has_key?(tombstone, :refresh_token)
    end

    @tag :auth_regression
    test "logout revokes a login-only host binding before any refresh", fixture do
      account = native_broker_login(fixture)

      assert {:ok, %{local: :logged_out, remote: :revoked}} =
               Auth.logout(fixture.server, account.account_ref)

      assert_receive {:revoke_request, revoked}
      assert revoked["client_id"] == @client
      assert revoked["token"] == "fixture-refresh"

      assert {:error, %Error{code: :logged_out}} =
               Auth.credentials(fixture.server, account.account_ref)
    end

    @tag :auth_regression
    test "a conflicting configured host still rejects returning login, refresh and revocation",
         fixture do
      account = native_broker_login(fixture)

      server =
        restart_native_broker(fixture,
          now: @now + 3_560,
          host_id: "urn:uuid:de809aea-5447-4fc5-9159-5676174ffbfd"
        )

      assert {:error, %Error{code: :host_binding_mismatch}} =
               Auth.begin_login(server,
                 account_ref: account.account_ref,
                 app_name: "Oh-My-Jido test host",
                 host_id: @host,
                 redirect_uri: @redirect
               )

      assert {:error, %Error{code: :host_binding_mismatch}} =
               Auth.credentials(server, account.account_ref)

      assert {:ok,
              %{
                local: :logged_out,
                remote: :unconfirmed,
                error: %Error{code: :host_binding_mismatch}
              }} = Auth.logout(server, account.account_ref)

      refute_receive {:token_request, _}
      refute_receive {:revoke_request, _}
      assert {:ok, stored} = FileStore.load(fixture.vault, account.account_ref)
      assert stored.host_id == @host
      assert stored.status == :logged_out
    end
  end

  defp native_broker_login(fixture) do
    assert {:ok, attempt} =
             Auth.begin_login(fixture.server,
               app_name: "Oh-My-Jido test host",
               host_id: @host,
               redirect_uri: @redirect
             )

    query = attempt.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["ext_agent_host_id"] == @host
    Agent.update(fixture.responses, fn _ -> token_response(fixture, query["nonce"]) end)

    assert {:ok, account} =
             Auth.complete_login(
               fixture.server,
               attempt.attempt_ref,
               callback(%{state: query["state"], redirect_uri: @redirect})
             )

    assert_receive {:token_request, %{"grant_type" => "authorization_code"}}
    account
  end

  defp restart_native_broker(fixture, provider_options) do
    stop_supervised(Broker)
    now = Keyword.get(provider_options, :now, @now)

    options =
      fixture.options
      |> Keyword.put(:clock, fn -> now end)
      |> Keyword.update!(:provider_options, &Keyword.merge(&1, provider_options))

    start_supervised!({Broker, options})
  end

  defp begin(overrides \\ []) do
    opts = [
      app_name: "Oh-My-Jido test host",
      host_id: "host-one",
      redirect_uri: @redirect,
      now: @now,
      req_options: [
        plug: fn conn -> Req.Test.json(conn, discovery()) end
      ]
    ]

    OpenAI.begin_login(Keyword.merge(opts, overrides))
  end

  defp callback(attempt, overrides \\ []) do
    params = %{
      "state" => attempt.state,
      "code" => "one-time-code",
      "client_id" => @client,
      "scope" => @scopes
    }

    params =
      Enum.reduce(overrides, params, fn {key, value}, params ->
        if value == nil,
          do: Map.delete(params, Atom.to_string(key)),
          else: Map.put(params, Atom.to_string(key), value)
      end)

    attempt.redirect_uri <> "?" <> URI.encode_query(params)
  end

  defp record do
    %{
      provider: :openai,
      access_mode: :subscription,
      client_id: @client,
      host_id: "host-one",
      issuer: @issuer,
      subject: "verified-account",
      scopes: String.split(@scopes),
      status: :active,
      expires_at: @now + 600,
      access_token: "old-access",
      refresh_token: "old-refresh",
      id_token: "retained-identity",
      redirect_uri: @redirect
    }
  end

  defp fixture_plug(fixture, tokens, parent) do
    fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, discovery())

        "/.well-known/jwks.json" ->
          Req.Test.json(conn, fixture.jwks)

        "/api/accounts/oauth/token" ->
          form = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> URI.decode_query()
          send(parent, {:token_request, form})

          fixture_token_response(conn, tokens)

        "/oauth/revoke" ->
          form = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> URI.decode_query()
          send(parent, {:revoke_request, form})
          Plug.Conn.send_resp(conn, 200, "")

        unexpected ->
          flunk("unexpected auth request: #{unexpected}")
      end
    end
  end

  defp fixture_token_response(conn, tokens) when is_function(tokens, 0),
    do: fixture_token_response(conn, tokens.())

  defp fixture_token_response(conn, tokens) do
    if Map.has_key?(tokens, :status),
      do: conn |> Plug.Conn.put_status(tokens.status) |> Req.Test.json(tokens.body),
      else: Req.Test.json(conn, tokens)
  end

  defp token_response(fixture, nonce, overrides \\ %{}) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "sub" => "verified-account",
          "aud" => @client,
          "exp" => @now + 600,
          "iat" => @now - 10,
          "nonce" => nonce
        },
        overrides
      )

    %{
      "access_token" => "fixture-access",
      "refresh_token" => "fixture-refresh",
      "id_token" => jwt(fixture.private, claims),
      "token_type" => "Bearer",
      "expires_in" => 3600,
      "scope" => @scopes
    }
  end

  defp forged_token(fixture, nonce) do
    [header, _, signature] = token_response(fixture, nonce)["id_token"] |> String.split(".")

    payload = %{
      "iss" => @issuer,
      "sub" => "forged",
      "aud" => @client,
      "exp" => @now + 600,
      "iat" => @now - 10,
      "nonce" => nonce
    }

    header <> "." <> encode_bytes(Jason.encode!(payload)) <> "." <> signature
  end

  defp jwt(private, claims) do
    signed =
      encode_bytes(Jason.encode!(%{"alg" => "RS256", "kid" => "test-key"})) <>
        "." <> encode_bytes(Jason.encode!(claims))

    signed <>
      "." <>
      encode_bytes(:crypto.sign(:rsa, :sha256, signed, private, rsa_padding: :rsa_pkcs1_padding))
  end

  defp encode_bytes(value), do: Base.url_encode64(value, padding: false)

  defp discovery do
    %{
      "issuer" => @issuer,
      "authorization_endpoint" => @issuer <> "/api/accounts/authorize",
      "token_endpoint" => @issuer <> "/api/accounts/oauth/token",
      "jwks_uri" => @issuer <> "/.well-known/jwks.json",
      "revocation_endpoint" => @issuer <> "/oauth/revoke",
      "id_token_signing_alg_values_supported" => ["RS256"]
    }
  end
end
