defmodule OhMyJido.Bench.Density.Metrics do
  @moduledoc false

  alias OhMyJido.Runtime

  def now, do: System.monotonic_time(:microsecond)
  def elapsed(started), do: (now() - started) / 1_000

  def distribution(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      min: List.first(sorted),
      max: List.last(sorted),
      p50: percentile(sorted, count, 0.50),
      p95: percentile(sorted, count, 0.95),
      p99: percentile(sorted, count, 0.99)
    }
  end

  def host do
    unless :os.type() == {:unix, :linux} and File.regular?("/proc/self/status") do
      raise ArgumentError, "density measurements require Linux procfs"
    end

    %{
      os: "linux",
      kernel_release: read_text("/proc/sys/kernel/osrelease"),
      architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      cpu_model: cpu_model(),
      logical_processors: :erlang.system_info(:logical_processors_available),
      physical_memory_bytes: proc_kib(read_text("/proc/meminfo"), "MemTotal"),
      cgroup: cgroup(),
      elixir_version: System.version(),
      elixir_build: System.build_info() |> Map.take([:build, :revision, :otp_release]),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      erts_version: :erlang.system_info(:version) |> List.to_string(),
      word_size_bytes: :erlang.system_info(:wordsize),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers_online: :erlang.system_info(:dirty_cpu_schedulers_online),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      beam_process_limit: :erlang.system_info(:process_limit),
      beam_port_limit: :erlang.system_info(:port_limit),
      mix_environment: Atom.to_string(Mix.env()),
      application_versions:
        Map.new([:oh_my_jido, :jido, :jido_ai, :jido_action, :req_llm], fn app ->
          version = Application.spec(app, :vsn)
          {app, if(version, do: to_string(version))}
        end),
      source_fingerprints: %{
        library_sha256: source_digest(Path.wildcard("lib/**/*.ex")),
        benchmark_sha256: source_digest(Path.wildcard("bench/*.exs")),
        mix_project_sha256: file_digest("mix.exs"),
        mix_lock_sha256: file_digest("mix.lock")
      },
      loaded_beam_sha256:
        Map.new(
          [
            Runtime,
            OhMyJido.Session,
            OhMyJido.CodingAgent,
            OhMyJido.Models.Transformer,
            Jido.AgentServer,
            Jido.AI.Test.ReActScript,
            Jido.AI.Reasoning.ReAct.Runner
          ],
          fn module ->
            digest =
              case :code.get_object_code(module) do
                {^module, bytes, _path} -> digest(bytes)
                :error -> nil
              end

            {Atom.to_string(module), digest}
          end
        ),
      executables:
        Map.new(["sh", "setsid", "mkfifo", "cat", "kill", "sleep"], fn name ->
          {name, System.find_executable(name)}
        end)
    }
  end

  def snapshot(runtime, origin) do
    started = now()
    pid = if runtime, do: Process.whereis(runtime)
    {tree, tree_errors} = supervised_tree(pid)

    mailboxes =
      Enum.flat_map(tree, fn child ->
        case Process.info(child, :message_queue_len) do
          {:message_queue_len, count} -> [count]
          nil -> []
        end
      end)

    %{
      at_ms: (started - origin) / 1_000,
      beam_memory_bytes: :erlang.memory() |> Map.new(),
      beam_process_count: :erlang.system_info(:process_count),
      beam_port_count: length(Port.list()),
      beam_run_queue: :erlang.statistics(:run_queue),
      os: os_snapshot(),
      runtime_supervised_process_count: length(mailboxes),
      runtime_tree_read_errors: tree_errors,
      session_coordinator_count: if(runtime, do: children_count(Runtime.sessions(runtime))),
      native_agent_supervisor_count:
        if(runtime,
          do: children_count(Jido.agent_supervisor_name(Runtime.engine(runtime)))
        ),
      leases:
        if(runtime,
          do: %{
            model: children_count(Module.concat(runtime, ModelSlots)),
            process: children_count(Module.concat(runtime, ProcessSlots)),
            subagent: children_count(Module.concat(runtime, SubagentSlots))
          },
          else: %{model: nil, process: nil, subagent: nil}
        ),
      mailboxes: %{
        runtime_total: Enum.sum(mailboxes),
        runtime_max: Enum.max(mailboxes, fn -> 0 end),
        runtime_nonempty: Enum.count(mailboxes, &(&1 > 0)),
        observed_runtime_processes: length(mailboxes),
        vanished_runtime_processes: length(tree) - length(mailboxes),
        observer:
          case Process.info(self(), :message_queue_len) do
            {:message_queue_len, count} -> count
            nil -> nil
          end
      }
    }
    |> then(fn sample -> Map.put(sample, :sampling_ms, elapsed(started)) end)
  end

  def pressure_summary(samples) do
    %{
      sample_count: length(samples),
      beam_process_count: distribution(Enum.map(samples, & &1.beam_process_count)),
      runtime_supervised_process_count:
        distribution(Enum.map(samples, & &1.runtime_supervised_process_count)),
      os_live_descendant_count: distribution(Enum.map(samples, & &1.os.live_descendant_count)),
      os_beam_rss_bytes: distribution(Enum.map(samples, & &1.os.beam_rss_bytes)),
      beam_total_memory_bytes: distribution(Enum.map(samples, & &1.beam_memory_bytes.total)),
      beam_run_queue: distribution(Enum.map(samples, & &1.beam_run_queue)),
      runtime_mailbox_total: distribution(Enum.map(samples, & &1.mailboxes.runtime_total)),
      runtime_mailbox_max: distribution(Enum.map(samples, & &1.mailboxes.runtime_max)),
      observer_mailbox: distribution(Enum.map(samples, & &1.mailboxes.observer)),
      sampling_ms: distribution(Enum.map(samples, & &1.sampling_ms)),
      model_leases:
        distribution(samples |> Enum.map(& &1.leases.model) |> Enum.reject(&is_nil/1)),
      process_leases:
        distribution(samples |> Enum.map(& &1.leases.process) |> Enum.reject(&is_nil/1)),
      runtime_tree_read_errors: Enum.sum(Enum.map(samples, & &1.runtime_tree_read_errors))
    }
  end

  def memory_delta(sample, baseline) do
    %{
      os_beam_rss_bytes: sample.os.beam_rss_bytes - baseline.os.beam_rss_bytes,
      beam_total_bytes: sample.beam_memory_bytes.total - baseline.beam_memory_bytes.total,
      beam_process_count: sample.beam_process_count - baseline.beam_process_count,
      runtime_supervised_process_count:
        sample.runtime_supervised_process_count - baseline.runtime_supervised_process_count
    }
  end

  def environment_fingerprint do
    bytes = System.get_env() |> Enum.sort() |> :erlang.term_to_binary()
    :crypto.hash(:sha256, bytes)
  end

  defp percentile(_values, 0, _quantile), do: nil

  defp percentile(values, count, quantile),
    do: Enum.at(values, max(ceil(count * quantile) - 1, 0))

  defp children_count(name) do
    case Process.whereis(name) do
      nil -> nil
      pid -> Supervisor.count_children(pid).active
    end
  catch
    :exit, _reason -> nil
  end

  defp supervised_tree(nil), do: {[], 0}
  defp supervised_tree(pid), do: walk_supervisors([pid], MapSet.new(), 0)

  defp walk_supervisors([], seen, errors), do: {MapSet.to_list(seen), errors}

  defp walk_supervisors([pid | rest], seen, errors) do
    if MapSet.member?(seen, pid) do
      walk_supervisors(rest, seen, errors)
    else
      seen = MapSet.put(seen, pid)

      case supervisor_children(pid) do
        {:ok, children} ->
          {supervisors, seen} =
            Enum.reduce(children, {[], seen}, fn
              {_id, child, :supervisor, _modules}, {pending, known} when is_pid(child) ->
                {[child | pending], known}

              {_id, child, _type, _modules}, {pending, known} when is_pid(child) ->
                {pending, MapSet.put(known, child)}

              _child, state ->
                state
            end)

          walk_supervisors(supervisors ++ rest, seen, errors)

        {:error, _reason} ->
          walk_supervisors(rest, seen, errors + 1)
      end
    end
  end

  defp supervisor_children(pid) do
    {:ok, Supervisor.which_children(pid)}
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp os_snapshot do
    status = File.read!("/proc/self/status")
    own_pid = System.pid() |> String.to_integer()
    {rows, errors} = os_descendants([own_pid], MapSet.new(), [], 0)
    live = Enum.reject(rows, &(&1.state in ["Z", "X"]))

    rss =
      Enum.flat_map(live, fn row ->
        if is_integer(row.rss_bytes), do: [row.rss_bytes], else: []
      end)

    %{
      beam_rss_bytes: proc_kib(status, "VmRSS"),
      beam_rss_high_water_bytes: proc_kib(status, "VmHWM"),
      live_descendant_count: length(live),
      descendant_rss_sum_bytes: Enum.sum(rss),
      descendant_rss_unavailable_count: length(live) - length(rss),
      descendant_scan_read_errors: errors,
      observed_zombie_descendant_count: length(rows) - length(live)
    }
  end

  defp os_descendants([], _seen, rows, errors), do: {rows, errors}

  defp os_descendants([parent | rest], seen, rows, errors) do
    if MapSet.member?(seen, parent) do
      os_descendants(rest, seen, rows, errors)
    else
      seen = MapSet.put(seen, parent)
      paths = Path.wildcard("/proc/#{parent}/task/*/children")

      {children, errors} =
        Enum.reduce(paths, {[], errors}, fn path, {found, failures} ->
          case File.read(path) do
            {:ok, contents} ->
              ids = contents |> String.split() |> Enum.map(&String.to_integer/1)
              {ids ++ found, failures}

            {:error, _reason} ->
              {found, failures + 1}
          end
        end)

      {new_rows, errors} =
        children
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(seen, &1))
        |> Enum.reduce({[], errors}, fn child, {found, failures} ->
          case File.read("/proc/#{child}/stat") do
            {:ok, stat} ->
              case Regex.run(~r/\A\d+ \(.*\) ([A-Z]) /s, stat) do
                [_, state] ->
                  row = %{
                    state: state,
                    rss_bytes: proc_kib(read_text("/proc/#{child}/status"), "VmRSS")
                  }

                  {[row | found], failures}

                _other ->
                  {found, failures + 1}
              end

            {:error, _reason} ->
              {found, failures + 1}
          end
        end)

      os_descendants(Enum.uniq(children) ++ rest, seen, new_rows ++ rows, errors)
    end
  end

  defp proc_kib(nil, _key), do: nil

  defp proc_kib(text, key) do
    case Regex.run(~r/^#{Regex.escape(key)}:\s+(\d+)\s+kB$/m, text) do
      [_, number] -> String.to_integer(number) * 1_024
      _missing -> nil
    end
  end

  defp cpu_model do
    case read_text("/proc/cpuinfo") do
      nil ->
        nil

      text ->
        case Regex.run(~r/^(?:model name|Hardware)\s*:\s*(.+)$/m, text) do
          [_, model] -> String.trim(model)
          _missing -> nil
        end
    end
  end

  defp cgroup do
    with text when is_binary(text) <- read_text("/proc/self/cgroup"),
         [_, group] <- Regex.run(~r/^0::(.*)$/m, text),
         root <- Path.expand("/sys/fs/cgroup/" <> String.trim_leading(group, "/")),
         true <- root == "/sys/fs/cgroup" or String.starts_with?(root, "/sys/fs/cgroup/") do
      %{
        version: "v2",
        cpu_max: read_text(Path.join(root, "cpu.max")),
        cpuset_cpus_effective: read_text(Path.join(root, "cpuset.cpus.effective")),
        memory_max_bytes: numeric_limit(Path.join(root, "memory.max")),
        pids_max: numeric_limit(Path.join(root, "pids.max"))
      }
    else
      _unavailable -> %{version: "unavailable"}
    end
  end

  defp numeric_limit(path) do
    case read_text(path) do
      "max" ->
        "unlimited"

      nil ->
        nil

      text ->
        case Integer.parse(text) do
          {value, ""} -> value
          _other -> nil
        end
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end

  defp source_digest(paths) do
    paths
    |> Enum.sort()
    |> Enum.map(fn path -> [path, 0, file_digest(path), 0] end)
    |> IO.iodata_to_binary()
    |> digest()
  end

  defp file_digest(path), do: path |> File.read!() |> digest()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
