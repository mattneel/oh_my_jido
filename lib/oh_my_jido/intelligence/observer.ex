defmodule OhMyJido.Intelligence.Observer do
  @moduledoc """
  Headless, read-only OTP observations for an explicitly configured live target.

  Bind `adapters: %{observer: {__MODULE__, target: :local}}` to opt into observing
  this VM, or use a trusted distributed node atom as `target`. Remote targets
  must already run this module; this adapter never starts distribution, sets a
  cookie, injects code or falls back to another target. The `:observe` grant is
  independent of `:eval`, `:debug` and `:mcp`.

  Supervision roots are a host-owned map of string labels to supervisor PIDs or
  registered names. Only those roots can be traversed. Snapshots are live and
  non-atomic: processes/tables can disappear during collection. Neither state,
  messages, dictionaries, application environment nor ETS contents are read.
  """

  alias OhMyJido.{Context, Tool}

  @process_fields [
    :registered_name,
    :status,
    :memory,
    :reductions,
    :message_queue_len,
    :initial_call,
    :current_function,
    :heap_size,
    :total_heap_size,
    :stack_size
  ]
  @table_fields [
    :name,
    :size,
    :memory,
    :type,
    :protection,
    :owner,
    :read_concurrency,
    :write_concurrency
  ]
  @system_fields [
    :process_count,
    :process_limit,
    :port_count,
    :port_limit,
    :atom_count,
    :atom_limit,
    :schedulers,
    :schedulers_online,
    :wordsize
  ]

  @spec invoke(Context.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(context, request, opts) do
    with {:ok, context} <- Context.fetch(context),
         :ok <- Tool.authorize(context, :observe, %{operation: request.operation}),
         {:ok, target} <- target(opts),
         {:ok, result} <- collect(target, request, opts),
         :ok <- bounded(context, result) do
      {:ok, result}
    end
  end

  defp target(opts) do
    case Keyword.get(opts, :target) do
      :local -> {:ok, node()}
      target when is_atom(target) and not is_nil(target) -> {:ok, target}
      _ -> {:error, {:capability_unavailable, :observer}}
    end
  end

  defp collect(target, request, opts) when target == node(), do: snapshot(request, opts)

  defp collect(target, request, opts) do
    timeout = min(Keyword.get(opts, :timeout_ms, 5_000), 30_000)
    :erpc.call(target, __MODULE__, :snapshot, [request, opts], timeout)
  catch
    :error, {:erpc, :timeout} -> {:error, :observer_timeout}
    :error, {:erpc, :noconnection} -> {:error, :observer_target_unavailable}
    :error, _reason -> {:error, :observer_target_failed}
    :exit, _reason -> {:error, :observer_target_failed}
  end

  @doc false
  @spec snapshot(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(request, opts) do
    with :ok <- valid_request(request) do
      result = observe(request, opts)

      case result do
        {:ok, observation} ->
          {:ok, Map.merge(observation, %{target: Atom.to_string(node()), atomic: false})}

        error ->
          error
      end
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :observer_observation_unavailable}
  catch
    :exit, {:timeout, _call} -> {:error, :observer_timeout}
    :exit, _reason -> {:error, :observer_observation_unavailable}
  end

  defp valid_request(%{operation: operation} = request)
       when operation in [
              :overview,
              :applications,
              :processes,
              :process,
              :supervision,
              :ets,
              :table
            ] do
    limit = Map.get(request, :limit, 50)
    offset = Map.get(request, :offset, 0)
    depth = Map.get(request, :depth, 3)

    if is_integer(limit) and limit in 1..200 and is_integer(offset) and offset in 0..100_000 and
         is_integer(depth) and depth in 1..5,
       do: :ok,
       else: {:error, :invalid_observer_bounds}
  end

  defp valid_request(_request), do: {:error, :unsupported_observer_operation}

  defp observe(%{operation: :overview}, _opts) do
    counters = Map.new(@system_fields, &{&1, :erlang.system_info(&1)})
    started = System.convert_time_unit(:erlang.system_info(:start_time), :native, :millisecond)

    {:ok,
     %{
       system:
         Map.merge(counters, %{
           otp_release: to_string(:erlang.system_info(:otp_release)),
           elixir_version: System.version(),
           uptime_ms: System.monotonic_time(:millisecond) - started,
           run_queue: :erlang.statistics(:run_queue),
           memory_bytes: Map.new(:erlang.memory())
         })
     }}
  end

  defp observe(%{operation: :applications} = request, _opts) do
    applications = :application.which_applications(2_000)

    page(applications, request, fn {name, _description, version} ->
      %{name: Atom.to_string(name), version: to_string(version)}
    end)
  end

  defp observe(%{operation: :processes} = request, _opts) do
    if function_exported?(:erlang, :processes_iterator, 0) do
      offset = Map.get(request, :offset, 0)
      limit = Map.get(request, :limit, 50)
      {pids, more} = process_page(:erlang.processes_iterator(), offset, limit, [])

      {entries, disappeared} =
        Enum.reduce(pids, {[], 0}, &collect_process_metadata/2)

      {:ok,
       %{
         entries: entries,
         offset: offset,
         count: length(entries),
         disappeared: disappeared,
         observed_total: :erlang.system_info(:process_count),
         truncated: more
       }}
    else
      {:error, :observer_process_iterator_unavailable}
    end
  end

  defp observe(%{operation: :process, pid: text}, _opts) when is_binary(text) do
    with {:ok, pid} <- parse_pid(text) do
      case process_metadata(pid) do
        nil -> {:error, :observer_process_gone}
        metadata -> {:ok, %{process: metadata}}
      end
    end
  end

  defp observe(%{operation: :ets} = request, _opts),
    do: page(:ets.all(), request, &table_metadata/1)

  defp observe(%{operation: :table, table: id}, _opts)
       when is_binary(id) and byte_size(id) <= 256 do
    case Enum.find(:ets.all(), &(inspect(&1) == id)) do
      nil ->
        {:error, :observer_table_gone}

      table ->
        case table_metadata(table) do
          nil -> {:error, :observer_table_gone}
          entry -> {:ok, %{table: entry}}
        end
    end
  end

  defp observe(%{operation: :supervision} = request, opts) do
    roots = Keyword.get(opts, :supervisors, %{})

    with true <- is_map(roots),
         {:ok, root} <- Map.fetch(roots, Map.get(request, :root)) do
      deadline = System.monotonic_time(:millisecond) + 5_000
      budget = Map.get(request, :limit, 50)
      depth = Map.get(request, :depth, 3)
      {rows, remaining, incomplete} = tree(root, nil, depth, budget, deadline, [])

      {:ok,
       %{
         root: request.root,
         entries: Enum.reverse(rows),
         truncated: incomplete,
         count: budget - remaining
       }}
    else
      _ -> {:error, :observer_supervisor_not_granted}
    end
  end

  defp observe(_request, _opts), do: {:error, :invalid_observer_request}

  defp collect_process_metadata(pid, {entries, disappeared}) do
    case process_metadata(pid) do
      nil -> {entries, disappeared + 1}
      entry -> {[entry | entries], disappeared}
    end
  end

  defp page(values, request, mapper) do
    offset = Map.get(request, :offset, 0)
    limit = Map.get(request, :limit, 50)
    selected = values |> Enum.drop(offset) |> Enum.take(limit)
    entries = selected |> Enum.map(mapper) |> Enum.reject(&is_nil/1)
    count = length(entries)
    selected_count = length(selected)
    total = length(values)

    {:ok,
     %{
       entries: entries,
       offset: offset,
       count: count,
       disappeared: selected_count - count,
       observed_total: total,
       truncated: offset + selected_count < total
     }}
  end

  defp process_page(iterator, offset, limit, pids) when offset > 0 do
    case :erlang.processes_next(iterator) do
      :none -> {pids, false}
      {_pid, next} -> process_page(next, offset - 1, limit, pids)
    end
  end

  defp process_page(iterator, 0, 0, pids),
    do: {pids, :erlang.processes_next(iterator) != :none}

  defp process_page(iterator, 0, limit, pids) do
    case :erlang.processes_next(iterator) do
      :none -> {pids, false}
      {pid, next} -> process_page(next, 0, limit - 1, [pid | pids])
    end
  end

  defp process_metadata(pid) do
    case :erlang.process_info(pid, @process_fields) do
      :undefined ->
        nil

      fields ->
        fields
        |> Map.new(fn {key, value} -> {key, metadata(value)} end)
        |> Map.put(:pid, pid_text(pid))
    end
  end

  defp table_metadata(table) do
    case :ets.info(table) do
      :undefined ->
        nil

      fields ->
        fields
        |> Keyword.take(@table_fields)
        |> Map.new(fn {key, value} -> {key, metadata(value)} end)
        |> Map.put(:id, inspect(table))
        |> Map.put(:memory_unit, "words")
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_pid(text) do
    if byte_size(text) <= 64 and Regex.match?(~r/\A<0\.\d+\.\d+>\z/, text) do
      {:ok, :erlang.list_to_pid(String.to_charlist(text))}
    else
      {:error, :invalid_observer_pid}
    end
  rescue
    ArgumentError -> {:error, :invalid_observer_pid}
  end

  defp tree(_supervisor, _parent, _depth, 0, _deadline, rows), do: {rows, 0, true}

  defp tree(supervisor, parent, depth, budget, deadline, rows) do
    if System.monotonic_time(:millisecond) >= deadline do
      {rows, budget, true}
    else
      tree_children(supervisor, parent, depth, budget, deadline, rows)
    end
  end

  defp tree_children(supervisor, parent, depth, budget, deadline, rows) do
    case children(supervisor, deadline) do
      {:ok, children} ->
        context = {supervisor, depth, deadline}
        Enum.reduce_while(children, {rows, budget, false}, &tree_child(&1, &2, context))

      {:error, reason} ->
        row = %{pid: metadata(supervisor), parent: metadata(parent), error: reason}
        {[row | rows], budget - 1, true}
    end
  end

  defp tree_child(_child, {rows, 0, _incomplete}, _context),
    do: {:halt, {rows, 0, true}}

  defp tree_child(
         {id, child, type, modules},
         {rows, remaining, incomplete},
         {supervisor, _depth, _deadline} = context
       ) do
    row = %{
      id: child_id(id),
      pid: metadata(child),
      parent: metadata(supervisor),
      type: type,
      modules: modules_metadata(modules)
    }

    descend_tree(child, type, context, {[row | rows], remaining - 1, incomplete})
  end

  defp descend_tree(
         child,
         :supervisor,
         {supervisor, depth, deadline},
         {rows, remaining, incomplete}
       )
       when is_pid(child) and depth > 1 do
    {rows, remaining, nested} =
      tree(child, supervisor, depth - 1, remaining, deadline, rows)

    {:cont, {rows, remaining, incomplete or nested}}
  end

  defp descend_tree(child, :supervisor, _context, {rows, remaining, _incomplete})
       when is_pid(child),
       do: {:cont, {rows, remaining, true}}

  defp descend_tree(_child, _type, _context, result), do: {:cont, result}

  defp children(supervisor, deadline) do
    timeout = max(1, min(1_000, deadline - System.monotonic_time(:millisecond)))
    {:ok, GenServer.call(supervisor, :which_children, timeout)}
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp child_id(id) when is_atom(id), do: Atom.to_string(id)
  defp child_id(_id), do: "opaque"

  defp modules_metadata(modules) when is_list(modules),
    do: Enum.map(Enum.take(modules, 8), &metadata/1)

  defp modules_metadata(:dynamic), do: "dynamic"
  defp metadata(nil), do: nil
  defp metadata(value) when is_pid(value), do: pid_text(value)
  defp metadata(value) when is_number(value) or is_boolean(value), do: value
  defp metadata(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata([]), do: nil

  defp metadata({module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity),
       do: %{module: Atom.to_string(module), function: Atom.to_string(function), arity: arity}

  defp metadata(_value), do: "opaque"
  defp pid_text(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @doc false
  @spec bounded(Context.t(), map()) :: :ok | {:error, term()}
  def bounded(context, result) do
    limit = min(Map.get(context.limits, :extension_result_bytes, 65_536), 131_072)

    case Jason.encode_to_iodata(result) do
      {:ok, encoded} ->
        if IO.iodata_length(encoded) <= limit,
          do: :ok,
          else: {:error, {:extension_result_limit, :observer, limit}}

      {:error, _reason} ->
        {:error, :invalid_observer_result}
    end
  end
end
