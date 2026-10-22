defmodule OhMyJido.Auth do
  @moduledoc """
  Manages human sign-in and account credentials through a supervised broker.

  Start a broker with an explicit vault and task supervisor, then initiate login:

      {:ok, login} = OhMyJido.Auth.begin_login(MyApp.Accounts)
      # Your application opens login.authorization_url and receives the callback.
      {:ok, account} =
        OhMyJido.Auth.complete_login(MyApp.Accounts, login.attempt_ref, callback)

  Your application owns the browser, callback listener, and human consent.
  Attempts are consumed once. The broker validates accounts, coordinates token
  refresh, and keeps credential records in the configured vault.
  Only opaque account references and safe metadata belong in sessions.

  `credentials/2` is privileged application code, not a model-facing tool.
  To use the broker as the runtime's credentials resolver, configure
  `credentials: {OhMyJido.Auth, broker: MyApp.Accounts}`.
  No other application's login or token files are read.

  Subscription failures never select another account or fall back to metered
  API billing. Choose API-key accounts explicitly in your own resolver and
  return per-request `api_key` options. See the Models and accounts guide.
  """

  alias OhMyJido.Auth.Broker

  @doc "Starts the broker with a protected vault and host Task.Supervisor."
  defdelegate start_link(opts), to: Broker

  @doc "Builds the account broker's supervision-tree entry."
  def child_spec(opts), do: Broker.child_spec(opts)

  @doc "Starts an explicit human sign-in attempt without opening a browser."
  defdelegate begin_login(server, opts \\ []), to: Broker

  @doc "Validates and consumes a callback once, committing only a validated account."
  defdelegate complete_login(server, attempt_ref, callback), to: Broker

  @doc "Cancels an unused or in-flight attempt without affecting existing account use."
  defdelegate cancel_login(server, attempt_ref), to: Broker

  @doc "Lists allowlisted metadata, never credential records or identity tokens."
  defdelegate list_accounts(server), to: Broker

  @doc "Obtains fresh, explicit per-request credentials for an opaque selected account."
  defdelegate credentials(server, account_ref), to: Broker

  @doc "Invalidates local use first and reports remote revocation separately."
  defdelegate logout(server, account_ref), to: Broker

  @doc "Credential callback helper for host adapters with a configured broker."
  def resolve(%OhMyJido.Context{}, account_ref, opts) do
    case Keyword.fetch(opts, :broker) do
      {:ok, server} -> Broker.credentials(server, account_ref)
      :error -> {:error, OhMyJido.Auth.Error.new(:broker_unavailable, %{provider: :local})}
    end
  end
end
