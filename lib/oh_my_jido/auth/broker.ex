defmodule OhMyJido.Auth.Broker do
  @moduledoc """
  Opaque multi-account OAuth lifecycle and single-flight credential renewal.

  A host supplies a protected `Auth.Vault` and an existing `Task.Supervisor`.
  Only validated provider login results enter the vault: there is no token-file
  import API. All network work runs outside the server. Account generations are
  persisted before logout, so a late refresh or login cannot restore old tokens.
  """
  use GenServer

  alias OhMyJido.Auth.{Error, OpenAI}
  alias OhMyJido.Models.Subscription

  @credential_fields [
    :provider,
    :access_mode,
    :client_id,
    :host_id,
    :issuer,
    :subject,
    :scopes,
    :expires_at,
    :access_token,
    :refresh_token,
    :id_token,
    :redirect_uri
  ]
  @metadata_fields [
    :account_ref,
    :provider,
    :access_mode,
    :status,
    :expires_at,
    :generation,
    :scopes
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def begin_login(server, opts \\ []), do: call(server, {:begin_login, opts}, 60_000)

  def complete_login(server, attempt_ref, callback),
    do: call(server, {:complete_login, attempt_ref, callback}, 60_000)

  def cancel_login(server, attempt_ref), do: call(server, {:cancel_login, attempt_ref})
  def list_accounts(server), do: call(server, :list_accounts)
  def credentials(server, account_ref), do: call(server, {:credentials, account_ref}, 60_000)
  def logout(server, account_ref), do: call(server, {:logout, account_ref}, 60_000)

  @impl true
  def init(opts) do
    with {vault, vault_opts} <- Keyword.get(opts, :store),
         {:ok, handle} <- vault_call(vault, :init, [vault_opts]),
         {:ok, references} when is_list(references) <- vault_call(vault, :list, [handle]),
         {:ok, accounts} <- load_accounts(vault, handle, references),
         tasks when not is_nil(tasks) <- Keyword.get(opts, :task_supervisor) do
      {:ok,
       %{
         vault: vault,
         handle: handle,
         tasks: tasks,
         accounts: accounts,
         generations: Map.new(accounts, fn {ref, record} -> {ref, record.generation} end),
         provider: Keyword.get(opts, :provider, OpenAI),
         provider_options: Keyword.get(opts, :provider_options, []),
         clock: Keyword.get(opts, :clock, fn -> System.system_time(:second) end),
         refresh_before: Keyword.get(opts, :refresh_before, 60),
         operation_timeout: Keyword.get(opts, :operation_timeout, 30_000),
         max_pending: Keyword.get(opts, :max_pending, 256),
         attempts: %{},
         operations: %{},
         refreshes: %{}
       }}
    else
      {:error, _reason} -> {:stop, Error.new(:vault_unavailable, %{provider: :local})}
      _invalid -> {:stop, Error.new(:invalid_broker_configuration, %{provider: :local})}
    end
  rescue
    _error -> {:stop, Error.new(:invalid_broker_configuration, %{provider: :local})}
  catch
    _kind, _reason -> {:stop, Error.new(:invalid_broker_configuration, %{provider: :local})}
  end

  @impl true
  def handle_call(message, from, state) do
    dispatch_call(message, from, state)
  rescue
    _error -> {:stop, :shutdown, {:error, Error.new(:broker_failed, %{provider: :local})}, state}
  catch
    _kind, _reason ->
      {:stop, :shutdown, {:error, Error.new(:broker_failed, %{provider: :local})}, state}
  end

  defp dispatch_call(:list_accounts, _from, state) do
    accounts =
      state.accounts |> Map.values() |> Enum.map(&metadata/1) |> Enum.sort_by(& &1.account_ref)

    {:reply, {:ok, accounts}, state}
  end

  defp dispatch_call({:begin_login, opts}, from, state) do
    selected = Keyword.get(opts, :account_ref)
    now = state.clock.()

    state = %{
      state
      | attempts:
          Map.reject(state.attempts, fn {_reference, attempt} -> attempt.expires_at <= now end)
    }

    with true <- map_size(state.attempts) + map_size(state.operations) < state.max_pending,
         {:ok, account} <- selected_account(state, selected) do
      provider_opts = provider_options(state, opts) |> Keyword.put(:account, account)
      reference = selected || random_reference("omj_acct_")
      generation = Map.get(state.generations, reference, 1)

      operation = %{
        kind: :begin_login,
        account_ref: reference,
        generation: generation,
        provider_options: provider_opts,
        waiters: [from]
      }

      state =
        state
        |> Map.put(:generations, Map.put(state.generations, reference, generation))
        |> start_operation(operation, fn ->
          provider_call(state.provider, :begin_login, [provider_opts])
        end)

      {:noreply, state}
    else
      false -> {:reply, {:error, Error.new(:auth_busy)}, state}
      {:error, reason} -> {:reply, {:error, Error.safe(reason)}, state}
    end
  end

  defp dispatch_call({:complete_login, attempt_ref, callback}, from, state) do
    case Map.pop(state.attempts, attempt_ref) do
      {nil, _attempts} ->
        {:reply, {:error, Error.new(:invalid_attempt)}, state}

      {attempt, attempts} ->
        state = %{state | attempts: attempts}

        complete_attempt(attempt_ref, attempt, callback, from, state)
    end
  end

  defp dispatch_call({:cancel_login, attempt_ref}, _from, state) do
    {_attempt, attempts} = Map.pop(state.attempts, attempt_ref)

    operation =
      Enum.find(state.operations, fn {_ref, op} ->
        op.kind == :login and op.attempt_ref == attempt_ref
      end)

    state = %{state | attempts: attempts}

    state =
      case operation do
        nil ->
          state

        {ref, op} ->
          Enum.each(op.waiters, &GenServer.reply(&1, {:error, Error.new(:login_cancelled)}))
          discard_operation(state, ref)
      end

    {:reply, :ok, state}
  end

  defp dispatch_call({:credentials, reference}, from, state) do
    account_credentials(Map.get(state.accounts, reference), reference, from, state)
  end

  defp dispatch_call({:logout, reference}, from, state) do
    logout_account(Map.get(state.accounts, reference), reference, from, state)
  end

  defp complete_attempt(attempt_ref, attempt, callback, from, state) do
    cond do
      attempt.expires_at <= state.clock.() ->
        {:reply, {:error, Error.new(:attempt_expired)}, state}

      Map.get(state.generations, attempt.account_ref) != attempt.generation ->
        {:reply, {:error, Error.new(:stale_credentials)}, state}

      true ->
        operation = %{
          kind: :login,
          account_ref: attempt.account_ref,
          generation: attempt.generation,
          attempt_ref: attempt_ref,
          waiters: [from]
        }

        state =
          start_operation(state, operation, fn ->
            provider_call(state.provider, :complete_login, [
              attempt,
              callback,
              attempt.provider_options
            ])
          end)

        {:noreply, state}
    end
  end

  defp account_credentials(nil, _reference, _from, state),
    do: {:reply, {:error, Error.new(:unknown_account)}, state}

  defp account_credentials(%{status: :logged_out}, _reference, _from, state),
    do: {:reply, {:error, Error.new(:logged_out)}, state}

  defp account_credentials(%{status: :reauth_required}, _reference, _from, state),
    do: {:reply, {:error, Error.new(:reauth_required)}, state}

  defp account_credentials(%{status: :consent_required}, _reference, _from, state),
    do: {:reply, {:error, Error.new(:consent_required)}, state}

  defp account_credentials(record, reference, from, state) do
    cond do
      record.expires_at > state.clock.() + state.refresh_before ->
        {:reply, credential_options(record), state}

      not present?(record[:refresh_token]) ->
        {:reply, {:error, Error.new(:credentials_expired, %{reauth_required: true})}, state}

      operation_ref = Map.get(state.refreshes, reference) ->
        join_refresh(state, operation_ref, from)

      map_size(state.operations) >= state.max_pending ->
        {:reply, {:error, Error.new(:auth_busy)}, state}

      true ->
        operation = %{
          kind: :refresh,
          account_ref: record.account_ref,
          generation: record.generation,
          waiters: [from]
        }

        state =
          start_operation(state, operation, fn ->
            provider_call(state.provider, :refresh, [record, lifecycle_options(state, record)])
          end)

        {:noreply, state}
    end
  end

  defp join_refresh(state, reference, from) do
    operation = Map.fetch!(state.operations, reference)

    if length(operation.waiters) < state.max_pending do
      operation = %{operation | waiters: [from | operation.waiters]}
      {:noreply, %{state | operations: Map.put(state.operations, reference, operation)}}
    else
      {:reply, {:error, Error.new(:auth_busy)}, state}
    end
  end

  defp logout_account(nil, _reference, _from, state),
    do: {:reply, {:error, Error.new(:unknown_account)}, state}

  defp logout_account(%{status: :logged_out}, _reference, _from, state),
    do: {:reply, {:ok, %{local: :logged_out, remote: :not_requested}}, state}

  defp logout_account(record, reference, from, state) do
    tombstone =
      record
      |> remove_tokens()
      |> Map.merge(%{status: :logged_out, generation: record.generation + 1})

    case persist(state, tombstone) do
      {:ok, updated} ->
        updated = invalidate_waiters(updated, reference)
        revoke_account(record, reference, tombstone.generation, from, updated)

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp revoke_account(record, reference, generation, from, state) do
    if present?(record[:refresh_token]) do
      operation = %{
        kind: :revoke,
        account_ref: reference,
        generation: generation,
        waiters: [from]
      }

      state =
        start_operation(state, operation, fn ->
          provider_call(state.provider, :revoke, [record, lifecycle_options(state, record)])
        end)

      {:noreply, state}
    else
      {:reply, {:ok, %{local: :logged_out, remote: :not_requested}}, state}
    end
  end

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(message, state) do
    dispatch_info(message, state)
  rescue
    _error -> {:stop, :shutdown, state}
  catch
    _kind, _reason -> {:stop, :shutdown, state}
  end

  defp dispatch_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.operations, reference) do
      {nil, _operations} ->
        {:noreply, state}

      {operation, operations} ->
        Process.demonitor(reference, [:flush])
        Process.cancel_timer(operation.timer)

        refreshes =
          if operation.kind == :refresh,
            do: Map.delete(state.refreshes, operation.account_ref),
            else: state.refreshes

        state = %{state | operations: operations, refreshes: refreshes}
        {reply, state} = finish_operation(state, operation, result)
        Enum.each(operation.waiters, &GenServer.reply(&1, reply))
        {:noreply, state}
    end
  end

  defp dispatch_info({:DOWN, reference, :process, _pid, _reason}, state) do
    if Map.has_key?(state.operations, reference) do
      dispatch_info(
        {reference, {:error, Error.new(:provider_unavailable, %{retryable: true})}},
        state
      )
    else
      {:noreply, state}
    end
  end

  defp dispatch_info({:auth_timeout, reference}, state) do
    case Map.get(state.operations, reference) do
      nil ->
        {:noreply, state}

      operation ->
        Task.shutdown(operation.task, :brutal_kill)
        dispatch_info({reference, {:error, Error.new(:auth_timeout, %{retryable: true})}}, state)
    end
  end

  defp dispatch_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp selected_account(_state, nil), do: {:ok, nil}

  defp selected_account(state, reference) do
    case Map.fetch(state.accounts, reference) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, Error.new(:unknown_account)}
    end
  end

  defp provider_options(state, options),
    do: Keyword.merge(Keyword.delete(options, :account_ref), state.provider_options)

  defp lifecycle_options(state, record),
    do: Keyword.put_new(state.provider_options, :host_id, record.host_id)

  defp start_operation(state, operation, function) do
    task = Task.Supervisor.async_nolink(state.tasks, function)
    timer = Process.send_after(self(), {:auth_timeout, task.ref}, state.operation_timeout)
    operation = Map.merge(operation, %{task: task, timer: timer})

    refreshes =
      if operation.kind == :refresh,
        do: Map.put(state.refreshes, operation.account_ref, task.ref),
        else: state.refreshes

    %{state | operations: Map.put(state.operations, task.ref, operation), refreshes: refreshes}
  end

  defp finish_operation(state, %{kind: :revoke}, result) do
    remote = if result == :ok, do: :revoked, else: :unconfirmed
    reply = %{local: :logged_out, remote: remote}

    reply =
      if remote == :unconfirmed,
        do: Map.put(reply, :error, safe_result_error(result)),
        else: reply

    {{:ok, reply}, state}
  end

  defp finish_operation(state, operation, result) do
    if Map.get(state.generations, operation.account_ref) != operation.generation do
      {{:error, Error.new(:stale_credentials)}, state}
    else
      finish_current(state, operation, result)
    end
  end

  defp finish_current(state, %{kind: :begin_login} = operation, {:ok, attempt})
       when is_map(attempt) do
    if is_binary(attempt[:authorization_url]) and is_integer(attempt[:expires_at]) do
      attempt_ref = random_reference("omj_login_")

      attempt =
        Map.merge(attempt, %{
          account_ref: operation.account_ref,
          generation: operation.generation,
          provider_options: operation.provider_options
        })

      {{:ok, %{attempt_ref: attempt_ref, authorization_url: attempt.authorization_url}},
       %{state | attempts: Map.put(state.attempts, attempt_ref, attempt)}}
    else
      {{:error, Error.new(:invalid_attempt)}, state}
    end
  end

  defp finish_current(state, operation, {:ok, result}) when is_map(result) do
    previous = Map.get(state.accounts, operation.account_ref)
    candidate = if operation.kind == :refresh, do: Map.merge(previous, result), else: result

    generation =
      if operation.kind == :login and previous != nil,
        do: operation.generation + 1,
        else: operation.generation

    with :ok <- immutable_identity(previous, candidate),
         {:ok, record} <-
           normalize_record(candidate, operation.account_ref, generation, state.clock.()),
         {:ok, state} <- persist(state, record) do
      state =
        if operation.kind == :login,
          do: invalidate_waiters(state, operation.account_ref),
          else: state

      reply =
        if operation.kind == :refresh,
          do: credential_options(record),
          else: {:ok, metadata(record)}

      {reply, state}
    else
      {:error, error} -> {{:error, Error.safe(error)}, state}
    end
  end

  defp finish_current(state, operation, result) do
    error = safe_result_error(result)

    if operation.kind == :refresh and Error.terminal?(error) do
      record =
        state.accounts
        |> Map.fetch!(operation.account_ref)
        |> remove_tokens()
        |> Map.put(:status, :reauth_required)

      case persist(state, record) do
        {:ok, state} -> {{:error, error}, state}
        {:error, vault_error} -> {{:error, vault_error}, state}
      end
    else
      {{:error, error}, state}
    end
  end

  defp normalize_record(record, reference, generation, now) do
    fields = [:client_id, :host_id, :issuer, :subject, :access_token]

    if record[:provider] == :openai and record[:access_mode] == :subscription and
         Enum.all?(fields, &present?(record[&1])) and is_integer(record[:expires_at]) and
         record.expires_at > now and is_list(record[:scopes]) and
         Enum.all?(record.scopes, &is_binary/1) do
      {:ok,
       record
       |> Map.take(@credential_fields)
       |> Map.merge(%{
         account_ref: reference,
         generation: generation,
         status: subscription_status(record.scopes)
       })}
    else
      {:error, Error.new(:invalid_credentials)}
    end
  end

  defp subscription_status(scopes) do
    if "chatgpt.tokens.use.direct" in scopes and "resource.invoke" in scopes,
      do: :active,
      else: :consent_required
  end

  defp immutable_identity(nil, _candidate), do: :ok

  defp immutable_identity(previous, candidate) do
    if Enum.all?(
         [:provider, :access_mode, :client_id, :host_id, :issuer, :subject],
         &(previous[&1] == candidate[&1])
       ),
       do: :ok,
       else: {:error, Error.new(:account_identity_mismatch)}
  end

  defp credential_options(%{status: :consent_required}),
    do: {:error, Error.new(:consent_required)}

  defp credential_options(record), do: Subscription.options(record.access_token)

  defp persist(state, record) do
    case vault_call(state.vault, :put, [state.handle, record.account_ref, record]) do
      :ok ->
        {:ok,
         %{
           state
           | accounts: Map.put(state.accounts, record.account_ref, record),
             generations: Map.put(state.generations, record.account_ref, record.generation)
         }}

      _failure ->
        {:error, Error.new(:vault_unavailable, %{provider: :local})}
    end
  end

  defp invalidate_waiters(state, reference) do
    Enum.reduce(state.operations, state, fn
      {operation_ref, %{account_ref: ^reference, kind: kind} = operation}, state
      when kind in [:refresh, :login, :begin_login] ->
        Enum.each(operation.waiters, &GenServer.reply(&1, {:error, Error.new(:logged_out)}))
        discard_operation(state, operation_ref)

      _operation, state ->
        state
    end)
  end

  defp discard_operation(state, reference) do
    case Map.pop(state.operations, reference) do
      {nil, _operations} ->
        state

      {operation, operations} ->
        Process.cancel_timer(operation.timer)
        Task.shutdown(operation.task, :brutal_kill)

        refreshes =
          if operation.kind == :refresh,
            do: Map.delete(state.refreshes, operation.account_ref),
            else: state.refreshes

        %{state | operations: operations, refreshes: refreshes}
    end
  end

  defp load_accounts(vault, handle, references) do
    Enum.reduce_while(references, {:ok, %{}}, fn reference, {:ok, accounts} ->
      case vault_call(vault, :load, [handle, reference]) do
        {:ok, %{account_ref: ^reference, generation: generation, status: status} = record}
        when is_integer(generation) and generation > 0 and
               status in [:active, :consent_required, :logged_out, :reauth_required] ->
          {:cont, {:ok, Map.put(accounts, reference, record)}}

        _error ->
          {:halt, {:error, :vault_corrupt}}
      end
    end)
  end

  defp provider_call(provider, function, arguments) do
    case apply(provider, function, arguments) do
      :ok when function == :revoke -> :ok
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, error} -> {:error, Error.safe(error)}
      _invalid -> {:error, Error.new(:provider_error)}
    end
  rescue
    _error -> {:error, Error.new(:provider_error)}
  catch
    _kind, _reason -> {:error, Error.new(:provider_error)}
  end

  defp vault_call(vault, function, arguments) do
    apply(vault, function, arguments)
  rescue
    _error -> {:error, :vault_unavailable}
  catch
    _kind, _reason -> {:error, :vault_unavailable}
  end

  defp call(server, message, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> {:error, Error.new(:broker_unavailable, %{provider: :local})}
  end

  defp safe_result_error({:error, error}), do: Error.safe(error)
  defp safe_result_error(_result), do: Error.new(:provider_error)
  defp remove_tokens(record), do: Map.drop(record, [:access_token, :refresh_token, :id_token])
  defp metadata(record), do: Map.take(record, @metadata_fields)
  defp present?(value), do: is_binary(value) and byte_size(value) > 0

  defp random_reference(prefix),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
