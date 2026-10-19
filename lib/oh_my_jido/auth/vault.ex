defmodule OhMyJido.Auth.Vault do
  @moduledoc """
  Protected host-owned credential storage used only by the account broker.

  Implementations must encrypt credentials or use an operating-system protected
  credential service. Session storage and ReqLLM credential-file discovery are
  not vaults. The store handle and `load/2` results are privileged host data;
  consumers receive only opaque references and allowlisted account metadata.
  """

  @callback init(keyword()) :: {:ok, term()} | {:error, atom()}
  @callback list(term()) :: {:ok, [String.t()]} | {:error, atom()}
  @callback load(term(), String.t()) :: {:ok, map()} | {:error, atom()}
  @callback put(term(), String.t(), map()) :: :ok | {:error, atom()}
  @callback delete(term(), String.t()) :: :ok | {:error, atom()}
end
