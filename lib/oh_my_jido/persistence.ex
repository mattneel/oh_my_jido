defmodule OhMyJido.Persistence do
  @moduledoc false

  alias Jido.Persistence.Store
  alias OhMyJido.Redact

  @credential_fields [
    :base_llm_opts,
    :run_llm_opts,
    :base_req_http_options,
    :run_req_http_options
  ]
  @process_fields [:coordinator, :runtime_task_supervisor, :pending_input_server, :stream_to]
  @session_records [:effects, :runs, :children]
  @context_records [:completed_tools, :pending_tools, "completed_tools", "pending_tools"]

  @doc false
  @spec read_session(module() | Store.config(), {atom(), String.t()}) ::
          {:ok, map(), Store.condition()} | {:error, term()}
  def read_session(config, identity) do
    with {:ok, store} <- Store.open(config),
         {:ok, bytes, condition} <- Store.read(store, session_key(identity)),
         {:ok, saved} <- decode_session(bytes) do
      {:ok, saved, condition}
    end
  end

  @doc false
  @spec write_session(module() | Store.config(), {atom(), String.t()}, map(), Store.condition()) ::
          {:ok, Store.condition()} | {:error, term()}
  def write_session(config, identity, saved, condition) when is_map(saved) do
    bytes = :erlang.term_to_binary(saved, [:deterministic])
    key = session_key(identity)

    with {:ok, store} <- Store.open(config),
         :ok <- Store.compare_and_swap(store, key, condition, bytes) do
      next_condition(store, key, bytes, condition)
    end
  end

  defp next_condition(_store, _key, bytes, previous) when is_binary(previous),
    do: {:ok, bytes}

  defp next_condition(store, key, bytes, _previous) do
    # Missing and token-based records need one authoritative read to obtain the
    # adapter's next condition. Never guess an opaque token or replay a write.
    case Store.read(store, key) do
      {:ok, ^bytes, condition} -> {:ok, condition}
      {:ok, _changed, _condition} -> {:error, {:indeterminate, :session_changed_after_write}}
      {:error, _reason} -> {:error, {:indeterminate, :session_condition_unavailable}}
    end
  end

  @doc false
  def session_key({runtime, id}),
    do: :erlang.term_to_binary({:oh_my_jido, :session, 1, runtime, id}, [:deterministic])

  defp decode_session(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      saved when is_map(saved) and not is_struct(saved) -> {:ok, saved}
      _invalid -> {:error, :invalid_session_checkpoint}
    end
  rescue
    ArgumentError -> {:error, :invalid_session_checkpoint}
  end

  @doc false
  @spec clean_session(map(), [String.t()]) :: map()
  def clean_session(snapshot, secrets) do
    {structured, fields} =
      Map.split(snapshot, @session_records ++ [:context_policy, :retained])

    Map.merge(
      clean(fields, secrets),
      Map.new(structured, fn
        {key, records} when key in @session_records ->
          {key, clean_records(records, secrets)}

        {key, checkpoint} ->
          {key, clean_context_checkpoint(checkpoint, secrets)}
      end)
    )
  end

  @spec agent_checkpoint(pid(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def agent_checkpoint(agent_pid, secrets) do
    with %Jido.Agent{} = agent <- Jido.AgentServer.agent(agent_pid),
         {:ok, checkpoint} <- Jido.Agent.checkpoint(agent, %{}) do
      {:ok, clean(checkpoint, secrets)}
    end
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  @spec clean(term(), [String.t()]) :: term()
  def clean(value, secrets) when is_binary(value),
    do: Redact.sanitize(value, secrets, max(byte_size(value), 1))

  def clean(%module{} = value, secrets) do
    struct(module, clean(Map.from_struct(value), secrets))
  end

  def clean(value, secrets) when is_map(value) do
    value =
      case value do
        %{kind: :checkpoint, data: data} when is_map(data) ->
          Map.put(value, :data, Map.delete(data, :token))

        _other ->
          value
      end

    value = clean_encoded_content(value, secrets)

    Map.new(value, fn
      {key, _item} when key in @credential_fields -> {key, []}
      {key, _item} when key in [:checkpoint_token, "checkpoint_token"] -> {key, nil}
      {key, _item} when key in @process_fields -> {key, nil}
      {key, item} -> {key, if(Redact.credential_field?(key), do: nil, else: clean(item, secrets))}
    end)
  end

  def clean(value, secrets) when is_list(value), do: Enum.map(value, &clean(&1, secrets))

  def clean(value, secrets) when is_tuple(value),
    do: value |> Tuple.to_list() |> clean(secrets) |> List.to_tuple()

  def clean(value, _secrets) when is_pid(value) or is_reference(value) or is_function(value),
    do: nil

  def clean(value, _secrets), do: value

  defp clean_encoded_content(%{"data_encoding" => "base64", "data" => data} = value, secrets)
       when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> Map.put(value, "data", decoded |> clean(secrets) |> Base.encode64())
      :error -> Map.put(value, "data", nil)
    end
  end

  defp clean_encoded_content(%{data_encoding: "base64", data: data} = value, secrets)
       when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> Map.put(value, :data, decoded |> clean(secrets) |> Base.encode64())
      :error -> Map.put(value, :data, nil)
    end
  end

  defp clean_encoded_content(value, _secrets), do: value

  defp clean_context_checkpoint(checkpoint, secrets) when is_map(checkpoint) do
    {records, fields} = Map.split(checkpoint, @context_records)

    Map.merge(
      clean(fields, secrets),
      Map.new(records, fn {key, entries} -> {key, clean_records(entries, secrets)} end)
    )
  end

  defp clean_context_checkpoint(checkpoint, secrets), do: clean(checkpoint, secrets)

  # Journal keys are correlation values, not credential-bearing field names.
  # Their record contents still receive the ordinary recursive sanitation.
  defp clean_records(records, secrets) when is_map(records) do
    Map.new(records, fn {id, record} -> {clean(id, secrets), clean(record, secrets)} end)
  end

  defp clean_records(records, secrets), do: clean(records, secrets)
end
