defmodule OhMyJidoBrowser.Credentials do
  @moduledoc """
  Holds the OpenRouter API key used for model requests.

  The page keeps the key encrypted in IndexedDB (`public/secrets.js`), under
  an AES-GCM WebCrypto key that page scripts can use but not export. The key
  form sends the key straight to this process, not through the UI process.
  This process keeps the decrypted key in memory, never logs it, and redacts
  it from crash reports.

  It is also the runtime's credential resolver: `resolve/3` returns the key as
  explicit ReqLLM options for the `"openrouter"` account. Local WebLLM models
  are keyless and do not use an account or this resolver.
  """

  use GenServer

  alias Popcorn.JS

  @account "openrouter"
  @secret "openrouter-api-key"
  @timeout 10_000

  @load "({name}) => window.ohMyJidoSecrets.load(name)"
  @save "({name, text}) => window.ohMyJidoSecrets.save(name, text)"
  @remove "({name}) => window.ohMyJidoSecrets.remove(name)"

  @doc "Starts the key holder; `:notify` receives `{:credentials, event}` messages."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Account reference for sessions that use the saved key."
  @spec account() :: String.t()
  def account, do: @account

  @doc "Loads a saved key from browser storage. Call only after the page is ready."
  @spec load() :: :present | :missing | {:error, term()}
  def load, do: GenServer.call(__MODULE__, :load, @timeout + 1_000)

  @doc "Credential resolver callback for `OhMyJido.Host.Local`."
  @spec resolve(OhMyJido.Context.t(), term(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  def resolve(_context, @account, _config) do
    case GenServer.call(__MODULE__, :key) do
      {:ok, key} -> {:ok, [api_key: key]}
      :error -> {:error, :credentials_required}
    end
  end

  def resolve(_context, _account, _config), do: {:error, :unknown_account}

  @impl true
  def init(opts), do: {:ok, %{key: nil, notify: Keyword.get(opts, :notify, OhMyJidoBrowser.UI)}}

  @impl true
  def handle_call(:load, _from, state) do
    case JS.run(@load, %{name: @secret}, timeout: @timeout) do
      {:ok, key} when is_binary(key) and key != "" -> {:reply, :present, %{state | key: key}}
      {:ok, _missing} -> {:reply, :missing, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:key, _from, %{key: nil} = state), do: {:reply, :error, state}
  def handle_call(:key, _from, %{key: key} = state), do: {:reply, {:ok, key}, state}

  @impl true
  def handle_cast(["save", text], state) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:noreply, state}

      key ->
        case JS.run(@save, %{name: @secret, text: key}, timeout: @timeout) do
          {:ok, true} ->
            send(state.notify, {:credentials, :saved})
            {:noreply, %{state | key: key}}

          {:error, reason} ->
            send(state.notify, {:credentials, {:error, reason}})
            {:noreply, state}
        end
    end
  end

  def handle_cast(["forget"], state) do
    _ = JS.run(@remove, %{name: @secret}, timeout: @timeout)
    send(state.notify, {:credentials, :forgotten})
    {:noreply, %{state | key: nil}}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact_state/1)
    |> Map.replace_lazy(:message, &redact_message/1)
    |> Map.replace_lazy(:log, fn log -> Enum.map(log, &redact_message/1) end)
  end

  defp redact_state(%{key: key} = state) when is_binary(key), do: %{state | key: :redacted}
  defp redact_state(state), do: state

  defp redact_message({:"$gen_cast", ["save", _key]}), do: {:"$gen_cast", ["save", :redacted]}
  defp redact_message(message), do: message
end
