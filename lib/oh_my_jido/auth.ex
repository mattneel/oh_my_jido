defmodule OhMyJido.Auth do
  @moduledoc """
  Human-initiated authentication through an explicitly supervised account broker.

  `begin_login/2` returns an authorization URL and opaque attempt reference; the
  host owns its browser, callback listener, and human consent. Pass the exact
  received callback to `complete_login/3`. Only account references and safe
  metadata belong in sessions. No other application's login/token files are read.

  `credentials/2` is a privileged host callback boundary, not a model-facing tool.
  Subscription errors never choose a different account or metered API billing.
  An API-key account must instead be selected explicitly in the host's credential
  service and returned as explicit per-request `api_key` options.
  """

  alias OhMyJido.Auth.Broker

  @doc "Starts the broker with a protected vault and host Task.Supervisor."
  defdelegate start_link(opts), to: Broker

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
