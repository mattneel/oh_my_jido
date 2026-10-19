defmodule OhMyJido.AuthTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Auth
  alias OhMyJido.Auth.{Broker, Error, FileStore}

  defmodule FailingVault do
    defdelegate init(opts), to: FileStore
    defdelegate list(store), to: FileStore
    defdelegate load(store, reference), to: FileStore
    def put(_store, _reference, record), do: raise("vault failure with #{record.access_token}")
  end

  defmodule Provider do
    def begin_login(opts) do
      if observer = opts[:begin_login_observer] do
        send(observer, {:login_discovery_started, self()})

        receive do
          :release_login_discovery -> :ok
        end
      end

      {:ok,
       %{
         authorization_url: "https://example.invalid/authorize",
         state: "state",
         nonce: "nonce",
         verifier: "verifier",
         redirect_uri: "http://127.0.0.1:31337/callback",
         expires_at: 2_000,
         host_id: "local-test-host",
         account: opts[:account]
       }}
    end

    def complete_login(_attempt, callback, _opts) do
      label = callback.label

      {:ok,
       %{
         provider: :openai,
         access_mode: :subscription,
         client_id: "issued-#{label}",
         host_id: "local-test-host",
         issuer: "https://auth.openai.com",
         subject: "subject-#{label}",
         scopes: callback[:scopes] || ["openid", "resource.invoke", "chatgpt.tokens.use.direct"],
         status: :active,
         expires_at: callback[:expires_at] || 1_500,
         access_token: "access-#{label}",
         refresh_token: "refresh-#{label}",
         id_token: "id-#{label}"
       }}
    end

    def refresh(record, opts) do
      send(opts[:test_pid], {:refresh_started, self(), record.subject})

      receive do
        {:release, result} ->
          result

        :release ->
          {:ok, %{record | access_token: "rotated-#{record.subject}", expires_at: 3_000}}
      after
        5_000 -> {:error, Error.new(:transport_error, %{retryable: true})}
      end
    end

    def revoke(record, opts) do
      send(opts[:test_pid], {:revoke_requested, record.client_id})
      opts[:revoke_result] || :ok
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-auth-#{System.unique_integer([:positive])}")
    key = :crypto.strong_rand_bytes(32)
    tasks = start_supervised!(Task.Supervisor)

    opts = [
      store: {FileStore, path: root, key: fn -> key end},
      task_supervisor: tasks,
      provider: Provider,
      provider_options: [test_pid: self()],
      clock: fn -> 1_000 end,
      refresh_before: 60
    ]

    server = start_supervised!({Broker, opts})
    on_exit(fn -> File.rm_rf!(root) end)
    %{server: server, root: root, key: key, opts: opts}
  end

  test "accounts are opaque, isolated, encrypted and recoverable", context do
    first = login(context.server, "one")
    second = login(context.server, "two")
    assert first.account_ref != second.account_ref
    refute Map.has_key?(first, :access_token)
    assert {:ok, one} = Auth.credentials(context.server, first.account_ref)
    assert {:ok, two} = Auth.credentials(context.server, second.account_ref)
    assert token(one) == "access-one"
    assert token(two) == "access-two"
    assert {:ok, [_, _] = accounts} = Auth.list_accounts(context.server)
    refute inspect(accounts) =~ "access-one"
    refute inspect(accounts) =~ "refresh-"
    status = :sys.get_status(context.server) |> inspect()
    refute status =~ "access-one"
    refute status =~ "refresh-one"
    assert {:ok, [_, _] = files} = File.ls(context.root)

    Enum.each(files, fn file ->
      bytes = File.read!(Path.join(context.root, file))
      refute bytes =~ "access-"
      refute bytes =~ "refresh-"
      assert Bitwise.band(File.stat!(Path.join(context.root, file)).mode, 0o777) == 0o600
    end)

    stop_supervised(Broker)
    restarted = start_supervised!({Broker, context.opts})
    assert {:ok, recovered} = Auth.credentials(restarted, first.account_ref)
    assert token(recovered) == "access-one"
  end

  test "slow login discovery neither blocks existing accounts nor resurrects a logged-out account",
       %{server: server} do
    account = login(server, "discovery")
    observer = self()

    caller =
      Task.async(fn ->
        Auth.begin_login(server,
          account_ref: account.account_ref,
          begin_login_observer: observer
        )
      end)

    assert_receive {:login_discovery_started, discovery}
    assert {:ok, credentials} = Auth.credentials(server, account.account_ref)
    assert token(credentials) == "access-discovery"
    assert {:ok, [metadata]} = Auth.list_accounts(server)
    assert metadata.status == :active
    assert {:ok, %{local: :logged_out}} = Auth.logout(server, account.account_ref)
    assert {:error, %Error{code: :logged_out}} = Task.await(caller)
    send(discovery, :release_login_discovery)
    assert {:error, %Error{code: :logged_out}} = Auth.credentials(server, account.account_ref)
  end

  test "all concurrent renewals join one per-account refresh while other accounts remain usable",
       %{server: server} do
    first = login(server, "old", expires_at: 1_020)
    other = login(server, "fresh")
    callers = for _ <- 1..8, do: Task.async(fn -> Auth.credentials(server, first.account_ref) end)
    assert_receive {:refresh_started, refresh, "subject-old"}
    assert {:ok, fresh} = Auth.credentials(server, other.account_ref)
    assert token(fresh) == "access-fresh"
    send(refresh, :release)

    Enum.each(callers, fn caller ->
      assert {:ok, opts} = Task.await(caller)
      assert token(opts) == "rotated-subject-old"
    end)

    refute_receive {:refresh_started, _, _}
  end

  test "different expired accounts refresh independently", %{server: server} do
    first = login(server, "parallel-one", expires_at: 1_020)
    second = login(server, "parallel-two", expires_at: 1_020)
    one = Task.async(fn -> Auth.credentials(server, first.account_ref) end)
    two = Task.async(fn -> Auth.credentials(server, second.account_ref) end)
    assert_receive {:refresh_started, first_worker, "subject-parallel-one"}
    assert_receive {:refresh_started, second_worker, "subject-parallel-two"}
    assert first_worker != second_worker
    send(first_worker, :release)
    send(second_worker, :release)
    assert {:ok, first_opts} = Task.await(one)
    assert {:ok, second_opts} = Task.await(two)
    assert token(first_opts) != token(second_opts)
  end

  test "remote revocation failure remains explicit while local logout survives restart",
       context do
    account = login(context.server, "unconfirmed")
    stop_supervised(Broker)

    options =
      Keyword.put(context.opts, :provider_options,
        test_pid: self(),
        revoke_result: {:error, Error.new(:transport_error, %{retryable: true})}
      )

    server = start_supervised!({Broker, options})

    assert {:ok,
            %{local: :logged_out, remote: :unconfirmed, error: %Error{code: :transport_error}}} =
             Auth.logout(server, account.account_ref)

    assert {:error, %Error{code: :logged_out}} = Auth.credentials(server, account.account_ref)
    stop_supervised(Broker)
    restarted = start_supervised!({Broker, options})
    assert {:error, %Error{code: :logged_out}} = Auth.credentials(restarted, account.account_ref)
  end

  test "pending returning-account login cannot override a later logout", %{server: server} do
    account = login(server, "returning")
    {:ok, attempt} = Auth.begin_login(server, account_ref: account.account_ref)
    assert {:ok, %{local: :logged_out}} = Auth.logout(server, account.account_ref)

    assert {:error, %Error{code: :stale_credentials}} =
             Auth.complete_login(server, attempt.attempt_ref, %{label: "returning"})

    assert {:error, %Error{code: :logged_out}} = Auth.credentials(server, account.account_ref)
  end

  test "logout invalidates in-flight refresh and cannot resurrect credentials", %{server: server} do
    account = login(server, "racing", expires_at: 1_020)
    caller = Task.async(fn -> Auth.credentials(server, account.account_ref) end)
    assert_receive {:refresh_started, refresh, "subject-racing"}

    assert {:ok, %{local: :logged_out, remote: :revoked}} =
             Auth.logout(server, account.account_ref)

    assert_receive {:revoke_requested, "issued-racing"}
    assert {:error, %Error{code: :logged_out}} = Task.await(caller)
    send(refresh, :release)
    assert {:error, %Error{code: :logged_out}} = Auth.credentials(server, account.account_ref)
    assert {:ok, [metadata]} = Auth.list_accounts(server)
    assert metadata.status == :logged_out
    assert metadata.generation > account.generation
  end

  test "terminal refresh errors revoke local use without exposing causes or switching billing", %{
    server: server
  } do
    account = login(server, "revoked", expires_at: 1_020)
    caller = Task.async(fn -> Auth.credentials(server, account.account_ref) end)
    assert_receive {:refresh_started, refresh, "subject-revoked"}
    send(refresh, {:release, {:error, Error.new(:invalid_grant, %{reauth_required: true})}})
    assert {:error, %Error{code: :invalid_grant}} = Task.await(caller)

    assert {:error, %Error{code: :reauth_required}} =
             Auth.credentials(server, account.account_ref)

    assert {:ok, [%{status: :reauth_required}]} = Auth.list_accounts(server)
  end

  test "temporary refresh failures retain account state and never fall back to ambient API keys",
       %{server: server} do
    account = login(server, "offline", expires_at: 1_020)
    caller = Task.async(fn -> Auth.credentials(server, account.account_ref) end)
    assert_receive {:refresh_started, refresh, "subject-offline"}

    send(
      refresh,
      {:release, {:error, %{message: "secret refresh-offline", api_key: "metered-secret"}}}
    )

    assert {:error, %Error{code: :provider_error} = error} = Task.await(caller)
    refute inspect(error) =~ "secret"
    assert {:ok, [%{status: :active}]} = Auth.list_accounts(server)
  end

  test "missing plan consent disables inference", %{server: server} do
    account = login(server, "identity-only", scopes: ["openid", "profile"])
    assert account.status == :consent_required

    assert {:error, %Error{code: :consent_required}} =
             Auth.credentials(server, account.account_ref)

    refute_receive {:refresh_started, _, _}
  end

  for missing_scope <- ["chatgpt.tokens.use.direct", "resource.invoke"] do
    @tag auth_regression: true, missing_scope: missing_scope
    test "login without #{missing_scope} persists consent-required and withholds credentials",
         context do
      scopes =
        ["openid", "resource.invoke", "chatgpt.tokens.use.direct"] -- [context.missing_scope]

      account = login(context.server, "missing-login-scope", scopes: scopes)
      reference = account.account_ref

      assert account.status == :consent_required
      assert {:ok, [^account]} = Auth.list_accounts(context.server)

      assert {:error, %Error{code: :consent_required}} =
               Auth.credentials(context.server, reference)

      assert {:ok, store} = FileStore.init(path: context.root, key: context.key)

      assert {:ok, %{status: :consent_required, scopes: ^scopes}} =
               FileStore.load(store, reference)

      stop_supervised(Broker)
      restarted = start_supervised!({Broker, context.opts})

      assert {:ok, [^account]} = Auth.list_accounts(restarted)
      assert {:error, %Error{code: :consent_required}} = Auth.credentials(restarted, reference)
      refute_receive {:refresh_started, _, _}
    end

    @tag auth_regression: true, missing_scope: missing_scope
    test "refresh without #{missing_scope} persists consent-required and withholds credentials",
         context do
      scopes = ["openid", "resource.invoke", "chatgpt.tokens.use.direct"]

      account =
        login(context.server, "missing-refresh-scope", scopes: scopes, expires_at: 1_020)

      assert account.status == :active
      reference = account.account_ref
      caller = Task.async(fn -> Auth.credentials(context.server, reference) end)
      assert_receive {:refresh_started, refresh, "subject-missing-refresh-scope"}
      granted = scopes -- [context.missing_scope]

      send(
        refresh,
        {:release,
         {:ok,
          %{
            access_token: "scope-reduced-access",
            refresh_token: "scope-reduced-refresh",
            expires_at: 3_000,
            scopes: granted,
            status: :consent_required
          }}}
      )

      assert {:error, %Error{code: :consent_required}} = Task.await(caller)

      assert {:ok, [%{account_ref: ^reference, status: :consent_required, scopes: ^granted}]} =
               Auth.list_accounts(context.server)

      assert {:error, %Error{code: :consent_required}} =
               Auth.credentials(context.server, reference)

      assert {:ok, store} = FileStore.init(path: context.root, key: context.key)

      assert {:ok, %{status: :consent_required, scopes: ^granted}} =
               FileStore.load(store, reference)

      stop_supervised(Broker)
      restarted = start_supervised!({Broker, context.opts})

      assert {:ok, [%{account_ref: ^reference, status: :consent_required, scopes: ^granted}]} =
               Auth.list_accounts(restarted)

      assert {:error, %Error{code: :consent_required}} = Auth.credentials(restarted, reference)
      refute_receive {:refresh_started, _, _}
    end
  end

  test "login attempts are single-use and cancelled attempts cannot complete", %{server: server} do
    assert {:ok, attempt} = Auth.begin_login(server, [])
    assert Map.keys(attempt) |> Enum.sort() == [:attempt_ref, :authorization_url]
    assert :ok = Auth.cancel_login(server, attempt.attempt_ref)

    assert {:error, %Error{code: :invalid_attempt}} =
             Auth.complete_login(server, attempt.attempt_ref, %{label: "cancelled"})

    account = login(server, "normal")
    assert is_binary(account.account_ref)
    assert {:error, %Error{code: :unknown_account}} = Auth.credentials(server, "not-an-account")
  end

  test "broker failures never expose a token-bearing callback in caller exit metadata" do
    {dead, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}

    assert {:error, %Error{code: :broker_unavailable} = error} =
             Auth.complete_login(dead, "attempt", "http://127.0.0.1/callback?code=private-grant")

    refute inspect(error) =~ "private-grant"
  end

  test "a host vault exception becomes a safe error without crashing or recording the account",
       context do
    options =
      Keyword.put(context.opts, :store, {FailingVault, path: context.root, key: context.key})

    server =
      start_supervised!(Supervisor.child_spec({Broker, options}, id: __MODULE__.FailingBroker))

    {:ok, attempt} = Auth.begin_login(server, [])

    assert {:error, %Error{code: :vault_unavailable} = error} =
             Auth.complete_login(server, attempt.attempt_ref, %{label: "private-vault-token"})

    refute inspect(error) =~ "private-vault-token"
    assert Process.alive?(server)
    assert {:ok, []} = Auth.list_accounts(server)
  end

  test "unexpected broker callback failure cannot leak credential state or callback arguments", %{
    server: server
  } do
    login(server, "guarded")
    monitor = Process.monitor(server)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{code: :broker_failed}} =
                 Auth.begin_login(server, "unexpected input containing access-guarded")

        assert_receive {:DOWN, ^monitor, :process, ^server, :shutdown}
      end)

    refute log =~ "access-guarded"
    refute log =~ "refresh-guarded"
    refute log =~ "unexpected input"
  end

  test "reference vault rejects wrong keys and tampering", %{root: root, key: key} do
    assert {:ok, store} = FileStore.init(path: root, key: key)
    assert {:ok, provided} = FileStore.init(path: root, key: fn -> key end)
    assert provided == store
    refute inspect(store) =~ inspect(key)
    reference = "omj_acct_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    assert :ok = FileStore.put(store, reference, %{token: "protected"})
    assert {:ok, wrong} = FileStore.init(path: root, key: :crypto.strong_rand_bytes(32))
    assert {:error, :vault_corrupt} = FileStore.load(wrong, reference)
    [file] = File.ls!(root)
    path = Path.join(root, file)
    <<first, rest::binary>> = File.read!(path)
    File.write!(path, <<Bitwise.bxor(first, 1), rest::binary>>)
    assert {:error, :vault_corrupt} = FileStore.load(store, reference)
    assert {:error, :invalid_vault_key} = FileStore.init(path: root, key: "short")

    assert {:error, :invalid_vault_key} =
             FileStore.init(path: root, key: fn -> raise "private key-provider error" end)
  end

  test "provider errors retain safe usage classifications only" do
    error =
      Error.from_response(
        429,
        %{"error" => %{"code" => "usage_limit_reached", "message" => "Bearer raw-access-token"}},
        %{"x-request-id" => ["req-safe"]}
      )

    assert %Error{code: :usage_limit, status: 429, request_id: "req-safe"} = error
    refute inspect(error) =~ "raw-access-token"

    assert Error.from_response(403, %{"error" => %{"code" => "subscription_required"}}).code ==
             :ineligible

    assert Error.from_response(401, %{"error" => %{"code" => "invalid_grant"}}).reauth_required
  end

  test "safe plan-limit metadata survives without raw provider fields or fabricated HTTP status" do
    error =
      Error.from_response(nil, %{
        "error" => %{
          "code" => "subscription_sharing_usage_limit_exceeded",
          "retry_after" => 120,
          "quota" => %{
            "remaining" => 0,
            "limit" => 100,
            "reset_at" => 2_000,
            "access_token" => "secret"
          },
          "message" => "secret raw provider message"
        }
      })

    assert error.status == nil
    assert error.retry_after == 120
    assert error.quota == %{remaining: 0, limit: 100, reset_at: 2_000}
    refute error.retryable
    refute inspect(error) =~ "secret"

    unavailable =
      Error.from_response(nil, %{"error" => %{"code" => "subscription_sharing_usage_unavailable"}})

    assert unavailable.retryable

    rejected =
      Error.from_response(403, %{"error" => %{"code" => "subscription_sharing_user_not_eligible"}})

    assert rejected.eligibility == :ineligible
    assert Error.from_response(429, %{}, %{"retry-after" => ["30"]}).retry_after == 30
  end

  defp login(server, label, extra \\ []) do
    {:ok, attempt} = Auth.begin_login(server, [])

    {:ok, account} =
      Auth.complete_login(server, attempt.attempt_ref, Map.merge(%{label: label}, Map.new(extra)))

    account
  end

  defp token(opts) do
    Keyword.get(opts, :access_token) || get_in(opts, [:provider_options, :access_token])
  end
end
