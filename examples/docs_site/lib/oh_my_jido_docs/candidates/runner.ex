defmodule OhMyJidoDocs.Candidates.Runner do
  @moduledoc """
  Runs an explicitly configured executable with identity-checked Linux ownership.

  `run/3` is synchronous and belongs in the caller's `Task.Supervisor`. Its
  options are an absolute `:cwd`, an explicit `:env` map/keyword list,
  `:timeout_ms`, `:max_output_bytes`, a list of secret `:redactions`, an opaque
  `:cancel_ref`, optional infrastructure `:owner_pid`, and optional `:before_start`,
  `:on_start`, and `:on_scope` callbacks. An owner DOWN or
  `{:cancel, cancel_ref}` message to the process calling `run/3` cancels execution.
  No shell, host working directory change, or host environment mutation is
  involved. Ambient variable names are unset rather than inherited; even PATH
  and LANG must be supplied.
  The read-only Port gives the child /dev/null for stdin, not an interactive pipe.

  Linux procfs, util-linux `setsid`, `kill`, and Python 3 with Linux pidfd support
  are required. Helpers can be selected with `:setsid_executable`,
  `:kill_executable`, and `:candidate_python_executable` options or application
  configuration. Missing supervision fails closed. The trusted packaged Python
  keeper runs with isolated imports, not candidate code in the host VM.

  The keeper becomes a Linux child subreaper before launching the command in a
  separate session. Ordinary descendants reparent to it even if their immediate
  parent exits between observations. Its independent OS deadline uses the budget
  remaining after synchronous authorization, plus one second; TERM escalates to
  KILL after 250 milliseconds.
  `stop/1` requests cleanup by signaling only the verified keeper, never killing
  the ownership anchor before descendants settle. An unlinked Erlang watchdog
  makes the same request if the calling Task dies while the VM survives.

  Confirmed cleanup requires the keeper's durable identity-bound status and an
  actual `waitpid` ECHILD observation after the main command exited. Sampling an
  empty group, losing an anchor, or closing the Port is never settlement proof.
  An uncertain keeper remains alive to retain/reap its children while the runner
  returns bounded uncertainty. Status lives in a private directory under the
  configured `:data_dir`, outside authored source, and is retained for restart
  cleanup. This is not a hostile same-user sandbox or proof of no external
  effects. Uninterruptible kernel tasks have no promised reaping deadline.
  PID/start/boot checks around the keeper TERM syscall still have a non-atomic
  check-to-signal race; the keeper uses pidfds for its own child signals.

  Final receipts use string keys and JSON-safe values. `output_bytes` counts raw
  bytes actually received, including discarded bytes; `output_complete` and
  `truncated` retain uncertainty when a pipe must be closed. Output storage is
  bounded before redaction, and the returned UTF-8 output is bounded afterward.
  Secrets spanning Port chunks, and incomplete secret suffixes at a truncated
  boundary, are redacted. Neither the environment nor callback exceptions enter
  a receipt. `on_start` receives the keeper's partial receipt with status
  `running`, runs in a monitored process, and must finish by the execution
  deadline. A callback error, including `{:error, reason}`, dispatches no target.
  Only after success and fresh owner/cancel/deadline/keeper checks does the
  calling process durably acknowledge dispatch. The keeper must also fsync the
  acknowledgement directory before it can fork the target. `on_scope` receives
  the same launch receipt whenever its bounded `owned_processes` identity list
  or coverage changes. It is
  serialized after `on_start`, must return `:ok`, and shares the execution
  deadline. Persist these same-generation scope updates for restart cleanup
  with `stop/1`; do not reconstruct ownership from an arbitrary PID. Final
  receipts and `stop/1` results retain settlement-discovered identities.
  An authenticated keeper timeout remains `timed_out` with `deadline_exceeded`
  even when the command handles TERM with a zero exit and cleanup is confirmed.
  `scope_observed` distinguishes an observed scope from an early launch snapshot;
  `owned_processes_complete` becomes permanently false, with `scope_error`, if a
  scan/count/time bound or unreadable ancestry prevents complete observation.
  The trusted keeper discovers descendants through every owned process thread's
  bounded procfs `children` list; unrelated host processes are never scanned.
  Erlang refreshes only those authenticated, identity-bound observations.
  Partial history fails the execution, but an authenticated keeper ECHILD proof
  can still confirm physical cleanup after every descendant is reaped. These
  identities are observations, not an external-effects/same-user sandbox claim.
  PID/start/boot identities survive reparenting and group/session changes.

  `before_start` runs synchronously before opening any subprocess and must return
  `:ok`; rejection or an exception starts nothing. Its receipt carries a unique
  `launch_id`, allowing infrastructure to durably replace the prior generation
  before spawning. Cancellation, owner liveness and the deadline are checked
  again after it returns. `on_start` and final receipts retain that same ID;
  confirmation for an earlier launch never proves cleanup of a later one.

  `resources` contains bounded procfs owned-scope samples, not authoritative
  peaks or resource limits. `observed_peak_group_process_count` counts the owned
  processes across sessions. RSS sums can double-count shared pages. CPU ticks
  are the largest sampled sum of live members' utime + stime; exited/unsampled children
  are not retrospectively accounted. AT_CLKTCK and AT_PAGESZ come from the local
  process auxiliary vector when readable, otherwise their bases are unknown.
  No resource samples means nil observations, never invented zero usage.
  """

  @default_timeout_ms 60_000
  @default_output_bytes 1_048_576
  @term_grace_ms 250
  @signal_timeout_ms 500
  @reap_timeout_ms 500
  @cleanup_timeout_ms 4_000
  @identity_timeout_ms 1_000
  @poll_ms 10
  @os_allowance_ms 1_000
  @resource_interval_ms 250
  @resource_budget_ms 25
  @resource_process_limit 4_096
  @scope_interval_ms 50
  @scope_budget_ms 100
  # Full project tests can accumulate hundreds of short-lived OS identities.
  @owned_process_limit 1_024
  @keeper_status_max_bytes 524_288
  @keeper_stop_timeout_ms 3_000
  @dispatch_ack_max_bytes 4_096
  @listener_budget_ms 100
  @listener_fd_limit 4_096
  @listener_tcp_max_bytes 1_048_576
  @redacted "[REDACTED]"

  @type receipt :: %{String.t() => term()}

  @doc "Resolves an executable without executing it or inspecting credentials."
  @spec available(term()) :: {:ok, String.t()} | {:error, :unavailable}
  def available(executable) when is_binary(executable) and byte_size(executable) > 0 do
    if valid_string?(executable) do
      case System.find_executable(executable) do
        path when is_binary(path) -> {:ok, Path.expand(path)}
        nil -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def available(_executable), do: {:error, :unavailable}

  @doc "Runs a fixed argument vector, returning the observed, bounded receipt."
  @spec run(String.t(), [String.t()], keyword()) :: receipt()
  def run(executable, argv, opts \\ []) do
    start = now()
    started_at = timestamp()

    with {:ok, request} <- request(executable, argv, opts),
         {:ok, tools} <- tools(opts) do
      receipt =
        request.executable
        |> initial_receipt(argv, request.cwd, started_at)
        |> Map.put("args", Enum.map(argv, &safe_string(redact(&1, request.redactions, false))))
        |> put_limits(opts)

      if request.owner_pid == nil or Process.alive?(request.owner_pid) do
        execute(request, tools, receipt, start)
      else
        cancelled_before_start(receipt, start, "owner_down")
      end
    else
      {:error, reason} ->
        executable
        |> initial_receipt(argv, option(opts, :cwd), started_at)
        |> Map.put("error", Atom.to_string(reason))
        |> put_limits(opts)
        |> Map.put("effect", "not_started")
        |> Map.put("cleanup", %{"status" => "not_started"})
        |> finish_time(start)
    end
  end

  @doc """
  Idempotently settles an owned process scope from a live or persisted receipt.

  Both string-keyed JSON receipts and their atom-keyed equivalents are accepted.
  Identity mismatches, unreadable procfs, unknown membership, and signaling
  failures return explicit uncertainty rather than signaling an unverified PID.
  Zombie members are already terminated; the original Port owner/OS parent is
  responsible for reaping them. This function never claims to reap another
  Erlang process's Port.
  """
  @spec stop(map()) :: map()
  def stop(receipt) when is_map(receipt) do
    deadline = now() + @keeper_stop_timeout_ms
    receipt = recover_identity(receipt, min(deadline, now() + @identity_timeout_ms))

    result =
      with {:ok, identity} <- receipt_identity(receipt),
           :ok <- verify_leader(identity),
           {:ok, kill} <- receipt_kill(receipt),
           {:ok, _keeper} <- keeper_descriptor(receipt) do
        await_keeper(receipt, identity, kill, deadline, false)
      else
        {:error, reason} -> cleanup_error(reason)
      end

    launcher =
      if result["status"] in ["confirmed", "not_started"],
        do: stop_launcher(receipt, now() + @term_grace_ms),
        else: "unverified"

    result = Map.put(result, "launcher", launcher)

    if result["status"] in ["confirmed", "not_started"] and
         launcher not in ["already_exited", "terminated"] do
      result
      |> Map.put("status", "uncertain")
      |> Map.put("reason", "launcher_exit_unconfirmed")
    else
      result
    end
  end

  def stop(_receipt), do: cleanup_error(:invalid_receipt)

  @doc """
  Proves that an exact IPv4 loopback TCP listener currently belongs to the run.

  The live leader's PID, start ticks, boot ID, group and session must still
  match the receipt. A listening `127.0.0.1:port` socket inode must be open in a
  verified live member of the exact retained ownership scope, including a
  descendant in another group/session. Wildcard/IPv6 listeners, multiple
  distinct listening inodes, unreadable procfs, and exhausted scan bounds fail
  closed. Process and socket identities are checked again after
  finding the owner. This is a bounded current observation, not an atomic lease
  over a later HTTP connection; it sends no traffic and signals no process.
  """
  @spec listener_owned?(map(), pos_integer()) :: boolean()
  def listener_owned?(receipt, port)
      when is_map(receipt) and is_integer(port) and port > 0 and port <= 65_535 do
    deadline = now() + @listener_budget_ms

    with {:ok, identity} <- receipt_identity(receipt),
         true <- live_listener_leader?(identity),
         {:ok, observed, _status} <- keeper_snapshot(receipt, identity),
         {:ok, observed, members} <- observe_owned(observed, identity),
         true <- observed["owned_processes_complete"] != false,
         {:ok, inode} <- loopback_listener_inode(port, deadline),
         {:ok, owner} <-
           find_listener_owner(
             members,
             inode,
             deadline,
             @owned_process_limit,
             @listener_fd_limit
           ),
         true <- listener_owner_current?(owner, inode),
         {:ok, ^inode} <- loopback_listener_inode(port, deadline),
         true <- live_listener_leader?(identity),
         true <- listener_owner_current?(owner, inode),
         true <- now() < deadline do
      true
    else
      _unverified -> false
    end
  rescue
    _error -> false
  end

  def listener_owned?(_receipt, _port), do: false

  defp live_listener_leader?(identity) do
    case read_process(identity["pid"]) do
      {:ok, current} ->
        listener_process_current?(current, identity)

      {:error, _reason} ->
        false
    end
  end

  defp listener_process_current?(current, recorded) do
    current["pid"] == recorded["pid"] and current["start_time"] == recorded["start_time"] and
      current["process_group"] == recorded["process_group"] and
      current["session"] == recorded["session"] and current["state"] not in ["Z", "X"]
  end

  defp loopback_listener_inode(port, deadline) do
    endpoint =
      "0100007F:" <>
        (port |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0"))

    with {:ok, device} <- File.open("/proc/net/tcp", [:read, :binary, :raw]) do
      try do
        read_listener_rows(device, endpoint, deadline, 0, "", nil)
      after
        File.close(device)
      end
    end
  end

  defp read_listener_rows(device, endpoint, deadline, bytes, carry, inode) do
    if now() >= deadline or bytes >= @listener_tcp_max_bytes do
      {:error, :listener_scan_bound}
    else
      read_listener_page(device, endpoint, deadline, bytes, carry, inode)
    end
  end

  defp read_listener_page(device, endpoint, deadline, bytes, carry, inode) do
    case :file.read(device, min(8_192, @listener_tcp_max_bytes - bytes)) do
      {:ok, chunk} ->
        {tail, rows} = List.pop_at(:binary.split(carry <> chunk, "\n", [:global]), -1)

        with true <- byte_size(tail) <= 4_096,
             {:ok, inode} <- listener_rows(rows, endpoint, inode) do
          read_listener_rows(device, endpoint, deadline, bytes + byte_size(chunk), tail, inode)
        else
          _unverified -> {:error, :listener_table_unverified}
        end

      :eof ->
        case listener_rows([carry], endpoint, inode) do
          {:ok, inode} when is_binary(inode) -> {:ok, inode}
          _absent -> {:error, :listener_not_found}
        end

      {:error, _reason} ->
        {:error, :listener_table_unreadable}
    end
  end

  defp listener_rows(rows, endpoint, inode) do
    Enum.reduce_while(rows, {:ok, inode}, &listener_row(&1, endpoint, &2))
  end

  defp listener_row(row, endpoint, {:ok, found}) do
    fields = String.split(row)

    if Enum.at(fields, 1) == endpoint and Enum.at(fields, 3) == "0A" do
      listener_inode(Enum.at(fields, 9), found)
    else
      {:cont, {:ok, found}}
    end
  end

  defp listener_inode(candidate, found) do
    case Integer.parse(candidate || "") do
      {number, ""} when number > 0 ->
        if found == nil or found == candidate,
          do: {:cont, {:ok, candidate}},
          else: {:halt, {:error, :ambiguous_listener}}

      _invalid ->
        {:halt, {:error, :listener_inode_unreadable}}
    end
  end

  defp find_listener_owner([], _inode, _deadline, _processes, _fds),
    do: {:error, :listener_owner_not_found}

  defp find_listener_owner([member | rest], inode, deadline, processes, fds) do
    if processes <= 0 or fds <= 0 or now() >= deadline do
      {:error, :listener_scan_bound}
    else
      case listener_member_owner(member, inode, deadline, fds) do
        {:next, remaining} ->
          find_listener_owner(rest, inode, deadline, processes - 1, remaining)

        result ->
          result
      end
    end
  end

  defp listener_member_owner(member, inode, deadline, fds) do
    case read_process(member["pid"]) do
      {:ok, current} ->
        if listener_process_current?(current, member),
          do: listener_member_fd(current, inode, deadline, fds),
          else: {:next, fds}

      {:error, reason} when reason in [:enoent, :esrch] ->
        {:next, fds}

      {:error, _reason} ->
        {:error, :listener_process_unreadable}
    end
  end

  defp listener_member_fd(current, inode, deadline, fds) do
    case find_listener_fd(current["pid"], inode, deadline, fds) do
      {:ok, fd} ->
        {:ok, %{pid: current["pid"], fd: fd, identity: current}}

      result ->
        result
    end
  end

  defp find_listener_fd(pid, inode, deadline, budget) do
    target = "socket:[#{inode}]"

    with {:ok, entries} <- File.ls("/proc/#{pid}/fd") do
      Enum.reduce_while(
        entries,
        {:next, budget},
        &listener_fd_entry(&1, pid, target, deadline, &2)
      )
    end
  end

  defp listener_fd_entry(fd, pid, target, deadline, {:next, remaining}) do
    if remaining <= 0 or now() >= deadline do
      {:halt, {:error, :listener_scan_bound}}
    else
      read_listener_fd(File.read_link("/proc/#{pid}/fd/#{fd}"), fd, target, remaining)
    end
  end

  defp read_listener_fd({:ok, observed}, fd, target, remaining) do
    if observed == target,
      do: {:halt, {:ok, fd}},
      else: {:cont, {:next, remaining - 1}}
  end

  defp read_listener_fd({:error, reason}, _fd, _target, remaining)
       when reason in [:enoent, :esrch],
       do: {:cont, {:next, remaining - 1}}

  defp read_listener_fd({:error, _reason}, _fd, _target, _remaining) do
    {:halt, {:error, :listener_fd_unreadable}}
  end

  defp listener_owner_current?(owner, inode) do
    with {:ok, current} <- read_process(owner.pid),
         true <- listener_process_current?(current, owner.identity),
         {:ok, target} <- File.read_link("/proc/#{owner.pid}/fd/#{owner.fd}") do
      target == "socket:[#{inode}]"
    else
      _unverified -> false
    end
  end

  defp request(executable, argv, opts) do
    with true <- keyword_options?(opts),
         {:ok, executable} <- available(executable),
         cwd when is_binary(cwd) <- Keyword.get(opts, :cwd),
         true <- valid_directory?(cwd),
         true <- valid_arguments?(argv),
         {:ok, env} <- environment(Keyword.get(opts, :env, [])),
         timeout when is_integer(timeout) and timeout > 0 <-
           Keyword.get(opts, :timeout_ms, @default_timeout_ms),
         limit when is_integer(limit) and limit >= 0 <-
           Keyword.get(opts, :max_output_bytes, @default_output_bytes),
         redactions when is_list(redactions) <- Keyword.get(opts, :redactions, []),
         true <- Enum.all?(redactions, &valid_redaction?/1),
         callback <- Keyword.get(opts, :on_start),
         true <- valid_callback?(callback),
         before_start <- Keyword.get(opts, :before_start),
         true <- valid_callback?(before_start),
         scope_callback <- Keyword.get(opts, :on_scope),
         true <- valid_callback?(scope_callback),
         owner_pid <- Keyword.get(opts, :owner_pid),
         true <- valid_owner?(owner_pid) do
      {:ok,
       %{
         executable: executable,
         argv: argv,
         cwd: cwd,
         env: env,
         timeout: timeout,
         limit: limit,
         redactions: Enum.uniq(redactions),
         cancel_ref: Keyword.get(opts, :cancel_ref),
         callback: callback,
         before_start: before_start,
         scope_callback: scope_callback,
         owner_pid: owner_pid
       }}
    else
      {:error, :unavailable} -> {:error, :executable_unavailable}
      _invalid -> {:error, :invalid_options}
    end
  end

  defp keyword_options?(opts), do: is_list(opts) and Keyword.keyword?(opts)

  defp valid_directory?(cwd),
    do: valid_string?(cwd) and Path.type(cwd) == :absolute and File.dir?(cwd)

  defp valid_arguments?(argv), do: is_list(argv) and Enum.all?(argv, &valid_string?/1)
  defp valid_redaction?(redaction), do: is_binary(redaction) and byte_size(redaction) > 0
  defp valid_callback?(callback), do: is_nil(callback) or is_function(callback, 1)
  defp valid_owner?(owner_pid), do: is_nil(owner_pid) or is_pid(owner_pid)

  defp tools(opts) do
    with {:unix, :linux} <- :os.type(),
         {:ok, boot_id} <- File.read("/proc/sys/kernel/random/boot_id"),
         {:ok, setsid} <- helper(opts, :setsid_executable, "setsid"),
         {:ok, python} <- helper(opts, :candidate_python_executable, "python3"),
         {:ok, kill} <- helper(opts, :kill_executable, "kill"),
         script when is_binary(script) <- keeper_script(),
         true <- File.regular?(script) do
      {:ok,
       %{
         setsid: setsid,
         python: python,
         keeper_script: script,
         kill: kill,
         boot_id: String.trim(boot_id),
         resource_basis: resource_basis()
       }}
    else
      _unavailable -> {:error, :process_supervision_unavailable}
    end
  end

  defp helper(opts, key, default) do
    available(Keyword.get(opts, key, Application.get_env(:oh_my_jido_docs, key, default)))
  end

  defp keeper_script do
    case :code.priv_dir(:oh_my_jido_docs) do
      path when is_list(path) -> Path.join(List.to_string(path), "candidate_process_keeper.py")
      _unavailable -> nil
    end
  end

  defp prepare_keeper(tools, receipt) do
    data =
      Application.get_env(
        :oh_my_jido_docs,
        :data_dir,
        Path.join(System.tmp_dir!(), "oh-my-jido-docs")
      )

    root = Path.join(Path.expand(data), "candidate-processes")
    directory = Path.join(root, receipt["launch_id"])

    with :ok <- File.mkdir_p(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- sync_receipt_directory(root),
         :ok <- sync_receipt_directory(Path.dirname(root)),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- sync_receipt_directory(directory),
         :ok <- sync_receipt_directory(root) do
      {:ok,
       %{
         "schema" => 2,
         "launch_id" => receipt["launch_id"],
         "status_path" => Path.join(directory, "status.json"),
         "executable" => tools.python,
         "script" => tools.keeper_script
       }}
    else
      _unavailable -> {:error, :process_supervision_unavailable}
    end
  end

  defp keeper_argv(request, keeper, milliseconds) do
    [
      "--fork",
      "--wait",
      "--",
      keeper["executable"],
      "-I",
      "-B",
      "-S",
      keeper["script"],
      "--status",
      keeper["status_path"],
      "--launch-id",
      keeper["launch_id"],
      "--timeout-ms",
      Integer.to_string(milliseconds),
      "--",
      request.executable | request.argv
    ]
  end

  defp receipt_kill(receipt) do
    case field(receipt, :kill_executable) do
      nil -> helper([], :kill_executable, "kill")
      executable -> available(executable)
    end
  end

  defp environment(env) when is_map(env) or is_list(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn
      {key, value}, {:ok, result} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if valid_string?(key) and key != "" and not String.contains?(key, "=") and
             (is_nil(value) or valid_string?(value)) do
          {:cont, {:ok, Map.put(result, key, value)}}
        else
          {:halt, {:error, :invalid_environment}}
        end

      _entry, _result ->
        {:halt, {:error, :invalid_environment}}
    end)
  end

  defp environment(_env), do: {:error, :invalid_environment}

  defp explicit_environment(env) do
    # Port's env option is an overlay, not a replacement. Enumerate names only
    # for removal; never select/copy ambient values into the child request.
    cleared = Map.new(System.get_env(), fn {key, _value} -> {key, nil} end)

    cleared
    |> Map.merge(env)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
    end)
  end

  defp prelaunch(request, deadline) do
    ref = request.cancel_ref

    cond do
      now() >= deadline ->
        {:cancelled, "deadline_before_launch"}

      request.owner_pid != nil and not Process.alive?(request.owner_pid) ->
        {:cancelled, "owner_down"}

      is_nil(ref) ->
        :ok

      true ->
        receive do
          {:cancel, ^ref} -> {:cancelled, "cancelled_before_launch"}
        after
          0 -> :ok
        end
    end
  end

  defp cancelled_before_start(receipt, start, reason) do
    receipt
    |> Map.put(
      "status",
      if(reason == "deadline_before_launch", do: "timed_out", else: "cancelled")
    )
    |> Map.put("cancellation", "not_started")
    |> Map.put("effect", "not_started")
    |> Map.put("cleanup", %{"status" => "not_started"})
    |> Map.put("error", reason)
    |> Map.put("deadline_exceeded", reason == "deadline_before_launch")
    |> finish_time(start)
  end

  defp authorize_start(%{before_start: nil}, _receipt), do: :ok

  defp authorize_start(request, receipt) do
    case request.before_start.(receipt) do
      :ok -> :ok
      _ -> {:error, :launch_not_authorized}
    end
  catch
    _kind, _reason -> {:error, :launch_not_authorized}
  end

  defp execute(request, tools, receipt, start) do
    receipt = Map.put(receipt, "launch_id", Ecto.UUID.generate())

    # Authorization remains synchronous and precedes every subprocess, including
    # the trusted keeper. Creating its private evidence directory executes none.

    opened =
      with :ok <- authorize_start(request, receipt),
           :ok <- prelaunch(request, start + request.timeout),
           {:ok, keeper} <- prepare_keeper(tools, receipt),
           :ok <- prelaunch(request, start + request.timeout),
           milliseconds = max(start + request.timeout - now(), 0) + @os_allowance_ms,
           {:ok, port, pid, monitor} <-
             open_port(
               tools.setsid,
               keeper_argv(request, keeper, milliseconds),
               request.cwd,
               request.env
             ) do
        {:ok, port, pid, monitor, keeper, milliseconds}
      else
        {:cancelled, reason} -> {:not_started, reason}
        {:error, reason} -> {:launch_rejected, reason}
      end

    case opened do
      {:ok, port, launcher_pid, monitor, keeper, milliseconds} ->
        launcher_identity =
          case read_process(launcher_pid) do
            {:ok, identity} -> Map.put(identity, "boot_id", tools.boot_id)
            {:error, _reason} -> nil
          end

        receipt =
          receipt
          |> Map.put("launcher_pid", launcher_pid)
          |> Map.put("launcher_identity", launcher_identity)
          |> Map.put("kill_executable", tools.kill)
          |> Map.put("process_keeper", keeper)
          |> Map.put("dispatch", "pending")
          |> Map.put("timeout_ms", request.timeout)
          |> Map.put("os_timeout_ms", milliseconds)
          |> Map.put("max_output_bytes", request.limit)
          |> Map.put("resources", initial_resources(tools.resource_basis))

        state = %{
          request: request,
          tools: tools,
          receipt: receipt,
          start: start,
          deadline: start + request.timeout,
          identity_deadline: min(start + request.timeout, now() + @identity_timeout_ms),
          port: port,
          port_monitor: monitor,
          port_closed: false,
          owner_monitor: monitor_owner(request.owner_pid),
          eof: false,
          exit_status: nil,
          chunks: [],
          retained: 0,
          output_bytes: 0,
          reason: nil,
          cancel_requested: false,
          deadline_exceeded: false,
          error: nil,
          cleanup: nil,
          cleanup_job: nil,
          cleanup_deadline: nil,
          reap_deadline: nil,
          callback: nil,
          callback_kind: nil,
          callback_status: "not_requested",
          scope_pending: false,
          scope_status: if(request.scope_callback, do: "not_observed", else: "not_requested"),
          watchdog: nil,
          resource_next_sample: now()
        }

        state = start_watchdog(state)
        state |> discover_group() |> start_callback() |> collect() |> final_receipt()

      {:not_started, reason} ->
        cancelled_before_start(receipt, start, reason)

      {:launch_rejected, reason} ->
        receipt
        |> Map.put("error", Atom.to_string(reason))
        |> Map.put("effect", "not_started")
        |> Map.put("cleanup", %{"status" => "not_started"})
        |> finish_time(start)
    end
  end

  defp monitor_owner(nil), do: nil
  defp monitor_owner(pid), do: {pid, Process.monitor(pid)}

  defp open_port(executable, argv, cwd, env) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :in,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :eof,
        :hide,
        {:args, argv},
        {:cd, String.to_charlist(cwd)},
        {:env, explicit_environment(env)}
      ])

    Process.unlink(port)
    monitor = :erlang.monitor(:port, port)
    {:os_pid, pid} = Port.info(port, :os_pid)
    {:ok, port, pid, monitor}
  rescue
    _error -> {:error, :process_launch_failed}
  end

  defp discover_group(state) do
    case discover_identity(state.receipt, state.tools.boot_id) do
      {:ok, identity} ->
        receipt =
          state.receipt
          |> Map.put("os_pid", identity["pid"])
          |> Map.put("process_identity", identity)
          |> Map.put("owned_processes", [owned_identity(identity, state.tools.boot_id)])

        send(elem(state.watchdog, 0), {:identity, elem(state.watchdog, 1), receipt})
        %{state | receipt: receipt}

      {:error, _reason} ->
        if state.exit_status != nil or state.port_closed or state.reason != nil or
             now() >= state.identity_deadline do
          state
        else
          state |> receive_event(1) |> discover_group()
        end
    end
  end

  defp discover_identity(receipt, boot_id) do
    pid = field(receipt, :launcher_pid)
    recorded = field(receipt, :launcher_identity)

    with true <- is_integer(pid) and is_map(recorded),
         {:ok, current} <- read_process(pid),
         true <- current["start_time"] == field(recorded, :start_time),
         {:ok, children} <- File.read("/proc/#{pid}/task/#{pid}/children") do
      children
      |> String.split()
      |> Enum.reduce_while(
        {:error, :process_identity_unavailable},
        &discover_child_identity(&1, &2, pid, current, boot_id)
      )
    else
      _unavailable -> {:error, :process_identity_unavailable}
    end
  end

  defp discover_child_identity(text, result, pid, current, boot_id) do
    with {child, ""} <- Integer.parse(text),
         {:ok, identity} <- read_process(child),
         true <-
           identity["parent_pid"] == pid and identity["process_group"] == child and
             identity["session"] == child,
         {:ok, still_current} <- read_process(pid),
         true <- still_current["start_time"] == current["start_time"] do
      {:halt, {:ok, Map.put(identity, "boot_id", boot_id)}}
    else
      _unverified -> {:cont, result}
    end
  end

  defp start_watchdog(state) do
    owner = self()
    token = make_ref()
    receipt = state.receipt
    boot_id = state.tools.boot_id

    pid =
      spawn(fn ->
        monitor = Process.monitor(owner)
        watch_owner(owner, monitor, token, receipt, boot_id, nil)
      end)

    %{state | watchdog: {pid, token}}
  end

  defp watch_owner(owner, monitor, token, receipt, boot_id, callback_pid) do
    receive do
      {:identity, ^token, updated} ->
        updated = merge_scope(updated, receipt)
        watch_owner(owner, monitor, token, updated, boot_id, callback_pid)

      {:callback, ^token, pid} ->
        watch_owner(owner, monitor, token, receipt, boot_id, pid)

      {:finished, ^token} ->
        Process.demonitor(monitor, [:flush])

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        stop_after_owner_down(receipt, boot_id, callback_pid)
    after
      @scope_interval_ms ->
        updated = watch_scope(receipt)

        if scope_changed?(receipt, updated) do
          send(owner, {:runner_scope, self(), token, updated})
        end

        watch_owner(owner, monitor, token, updated, boot_id, callback_pid)
    end
  end

  defp stop_after_owner_down(receipt, boot_id, callback_pid) do
    if callback_pid, do: Process.exit(callback_pid, :kill)
    receipt |> discover_missing_identity(boot_id) |> stop()
  end

  defp discover_missing_identity(receipt, boot_id) do
    if field(receipt, :process_identity) do
      receipt
    else
      case discover_identity(receipt, boot_id) do
        {:ok, identity} ->
          receipt
          |> Map.put("os_pid", identity["pid"])
          |> Map.put("process_identity", identity)

        {:error, _reason} ->
          receipt
      end
    end
  end

  defp watch_scope(receipt) do
    case receipt_identity(receipt) do
      {:ok, identity} -> watch_owned_scope(receipt, identity)
      {:error, _reason} -> receipt
    end
  end

  defp watch_owned_scope(receipt, identity) do
    case observe_owned(receipt, identity) do
      {:ok, observed, _members} -> observed
      {:error, :process_keeper_status_unavailable} -> receipt
      {:error, reason} -> incomplete_scope(receipt, reason)
    end
  end

  defp start_callback(%{request: %{callback: nil}} = state), do: state

  defp start_callback(%{receipt: %{"process_identity" => nil}} = state) do
    %{state | callback_status: "not_started"}
  end

  defp start_callback(state) do
    receipt = state |> snapshot_output() |> Map.put("status", "running")

    state
    |> launch_callback(state.request.callback, receipt, :start)
    |> Map.put(:callback_status, "running")
  end

  defp launch_callback(state, callback, receipt, kind) do
    {pid, ref} =
      spawn_monitor(fn ->
        try do
          result = callback.(receipt)

          if match?({:error, _reason}, result) or (kind == :scope and result != :ok) do
            exit(if(kind == :start, do: :on_start_failed, else: :on_scope_failed))
          end
        catch
          _type, _reason -> exit(if(kind == :start, do: :on_start_failed, else: :on_scope_failed))
        end
      end)

    send(elem(state.watchdog, 0), {:callback, elem(state.watchdog, 1), pid})
    %{state | callback: {pid, ref}, callback_kind: kind}
  end

  defp acknowledge_dispatch(state) do
    cond do
      state.receipt["dispatch"] != "pending" or state.callback_kind == :start ->
        state

      state.reason != nil or state.cleanup_job != nil or state.cleanup != nil ->
        %{state | receipt: Map.put(state.receipt, "dispatch", "rejected")}

      state.callback_status not in ["passed", "not_requested"] ->
        dispatch_failure(state, :on_start_failed)

      true ->
        acknowledge_ready_dispatch(state)
    end
  end

  defp acknowledge_ready_dispatch(state) do
    case dispatch_authority(state) do
      {:ok, observed, ready} ->
        state |> record_scope(observed) |> persist_dispatch_ack(ready)

      {:cancelled, reason} ->
        dispatch_cancelled(state, reason)

      {:error, :process_keeper_status_unavailable} ->
        if now() < state.identity_deadline,
          do: state,
          else: dispatch_failure(state, :process_keeper_status_unavailable)

      {:error, reason} ->
        dispatch_failure(state, reason)
    end
  end

  defp persist_dispatch_ack(state, ready) do
    case write_dispatch_ack(state, ready) do
      :ok ->
        %{state | receipt: Map.put(state.receipt, "dispatch", "acknowledged")}

      {:cancelled, reason} ->
        dispatch_cancelled(state, reason)

      {:error, reason} ->
        dispatch_failure(state, reason)
    end
  end

  defp dispatch_authority(state) do
    with :ok <- prelaunch(state.request, state.deadline),
         {:ok, identity} <- receipt_identity(state.receipt),
         true <- live_listener_leader?(identity),
         {:ok, observed, ready} <- keeper_snapshot(state.receipt, identity),
         false <- ready["main_started"],
         "running" <- ready["status"],
         true <- observed["owned_processes_complete"] != false do
      {:ok, observed, ready}
    else
      {:cancelled, _reason} = cancelled -> cancelled
      {:error, _reason} = error -> error
      _unverified -> {:error, :process_keeper_dispatch_not_ready}
    end
  end

  defp write_dispatch_ack(state, ready) do
    destination = state.receipt["process_keeper"]["status_path"] <> ".ack"
    temporary = destination <> ".staging"

    bytes =
      Jason.encode!(%{
        "schema" => 1,
        "launch_id" => state.receipt["launch_id"],
        "keeper_identity" => ready["keeper_identity"]
      })

    with true <- byte_size(bytes) <= @dispatch_ack_max_bytes,
         {:error, :enoent} <- File.lstat(destination),
         {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(io, bytes),
             :ok <- :file.sync(io),
             {:ok, _observed, current} <- dispatch_authority(state),
             true <- current["keeper_identity"] == ready["keeper_identity"],
             :ok <- File.rename(temporary, destination),
             :ok <- sync_receipt_directory(Path.dirname(destination)) do
          :ok
        else
          false -> {:error, :process_keeper_identity_changed}
          {:cancelled, _reason} = cancelled -> cancelled
          {:error, _reason} = error -> error
        end
      after
        File.close(io)
        File.rm(temporary)
      end
    else
      false -> {:error, :dispatch_ack_too_large}
      {:ok, _existing} -> {:error, :dispatch_ack_already_exists}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def sync_receipt_directory(directory) do
    with {:ok, io} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      try do
        :file.sync(io)
      after
        :file.close(io)
      end
    end
  end

  defp dispatch_failure(state, reason) do
    %{
      state
      | receipt: Map.put(state.receipt, "dispatch", "rejected"),
        reason: state.reason || "failed",
        error: state.error || "dispatch_ack_#{reason}"
    }
  end

  defp dispatch_cancelled(state, reason) do
    deadline = reason == "deadline_before_launch"

    %{
      state
      | receipt: Map.put(state.receipt, "dispatch", "rejected"),
        reason: state.reason || if(deadline, do: "timed_out", else: "cancelled"),
        error: state.error || reason,
        cancel_requested: state.cancel_requested or not deadline,
        deadline_exceeded: state.deadline_exceeded or deadline
    }
  end

  defp start_scope_callback(state) do
    cond do
      not state.scope_pending or state.callback != nil ->
        state

      state.scope_status in ["failed", "timed_out"] ->
        %{state | scope_pending: false}

      now() >= state.deadline ->
        %{
          state
          | scope_pending: false,
            scope_status: "timed_out",
            reason: state.reason || "timed_out",
            deadline_exceeded: true
        }

      true ->
        receipt = state |> snapshot_output() |> Map.put("status", "running")

        state
        |> launch_callback(state.request.scope_callback, receipt, :scope)
        |> Map.put(:scope_pending, false)
        |> Map.put(:scope_status, "running")
    end
  end

  defp record_scope(state, observed) do
    receipt = merge_scope(state.receipt, observed)

    receipt =
      if state.cleanup == nil do
        Map.merge(
          receipt,
          Map.take(observed, ~w(keeper_status main_exit_status keeper_timed_out keeper_cancelled))
        )
      else
        receipt
      end

    changed = scope_changed?(state.receipt, receipt)
    incomplete = receipt["owned_processes_complete"] == false
    timed_out = observed["keeper_timed_out"] == true

    reason = observed_scope_reason(timed_out, incomplete)

    %{
      state
      | receipt: receipt,
        reason: state.reason || reason,
        error: state.error || if(incomplete, do: receipt["scope_error"], else: nil),
        deadline_exceeded: state.deadline_exceeded or timed_out,
        scope_pending: state.scope_pending or (changed and state.request.scope_callback != nil)
    }
  end

  defp observed_scope_reason(true, _incomplete), do: "timed_out"
  defp observed_scope_reason(_timed_out, true), do: "failed"
  defp observed_scope_reason(_timed_out, _incomplete), do: nil

  defp collect(state) do
    state =
      state |> advance() |> acknowledge_dispatch() |> sample_resources() |> start_scope_callback()

    if finished?(state) do
      state
    else
      state |> receive_event(wait_time(state)) |> collect()
    end
  end

  defp advance(state) do
    state
    |> enforce_execution_deadline()
    |> cancel_stale_callback()
    |> start_cleanup()
    |> enforce_cleanup_deadline()
    |> enforce_reap_deadline()
  end

  defp enforce_execution_deadline(state) do
    if now() >= state.deadline and
         (state.exit_status == nil or state.callback != nil or state.scope_pending) do
      %{state | reason: state.reason || "timed_out", deadline_exceeded: true}
    else
      state
    end
  end

  defp cancel_stale_callback(state) do
    if state.callback != nil and (now() >= state.deadline or state.reason != nil) do
      {pid, ref} = state.callback
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])

      state
      |> Map.put(:callback, nil)
      |> Map.put(:callback_kind, nil)
      |> Map.put(
        if(state.callback_kind == :start, do: :callback_status, else: :scope_status),
        if(now() >= state.deadline, do: "timed_out", else: "cancelled")
      )
    else
      state
    end
  end

  defp start_cleanup(state) do
    if cleanup_needed?(state) do
      owner = self()
      receipt = state.receipt

      {pid, ref} =
        spawn_monitor(fn -> send(owner, {:runner_cleanup, self(), stop(receipt)}) end)

      %{state | cleanup_job: {pid, ref}, cleanup_deadline: now() + @cleanup_timeout_ms}
    else
      state
    end
  end

  defp cleanup_needed?(state) do
    state.cleanup_job == nil and state.cleanup == nil and
      (state.reason != nil or state.exit_status != nil or state.port_closed or
         state.receipt["main_exit_status"] != nil or
         state.receipt["keeper_status"] == "uncertain")
  end

  defp enforce_cleanup_deadline(state) do
    if state.cleanup_job != nil and now() >= state.cleanup_deadline do
      {pid, ref} = state.cleanup_job
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])

      %{
        state
        | cleanup_job: nil,
          cleanup: cleanup_error(:cleanup_deadline),
          reap_deadline: now() + @reap_timeout_ms
      }
    else
      state
    end
  end

  defp enforce_reap_deadline(state) do
    if state.reap_deadline != nil and now() >= state.reap_deadline and not port_finished?(state) do
      close_port(state.port)
      %{state | port_closed: true}
    else
      state
    end
  end

  defp receive_event(state, timeout) do
    port = state.port
    port_monitor = state.port_monitor
    cancel_ref = state.request.cancel_ref

    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        retain_output(state, chunk)

      {^port, :eof} ->
        %{state | eof: true}

      {^port, {:exit_status, status}} ->
        %{state | exit_status: status}

      {:DOWN, ^port_monitor, :port, ^port, _reason} ->
        %{state | port_closed: true}

      {:cancel, ^cancel_ref} ->
        %{state | reason: state.reason || "cancelled", cancel_requested: true}

      {:runner_cleanup, pid, result} when state.cleanup_job != nil ->
        if elem(state.cleanup_job, 0) == pid do
          {_pid, ref} = state.cleanup_job
          Process.demonitor(ref, [:flush])
          state = record_scope(state, result)
          %{state | cleanup: result, cleanup_job: nil, reap_deadline: now() + @reap_timeout_ms}
        else
          state
        end

      {:runner_scope, pid, token, observed} when state.watchdog == {pid, token} ->
        record_scope(state, observed)

      {:DOWN, ref, :process, pid, reason}
      when state.callback == {pid, ref} ->
        status_field = if state.callback_kind == :start, do: :callback_status, else: :scope_status
        error = if state.callback_kind == :start, do: "on_start_failed", else: "on_scope_failed"
        state = %{state | callback: nil, callback_kind: nil}

        if reason == :normal do
          Map.put(state, status_field, "passed")
        else
          state
          |> Map.put(status_field, "failed")
          |> Map.put(:reason, state.reason || "failed")
          |> Map.put(:error, error)
        end

      {:DOWN, ref, :process, pid, _reason}
      when state.owner_monitor == {pid, ref} ->
        %{
          state
          | owner_monitor: nil,
            cancel_requested: true,
            reason: state.reason || "cancelled",
            error: "owner_down"
        }

      {:DOWN, ref, :process, pid, _reason}
      when state.cleanup_job == {pid, ref} ->
        %{
          state
          | cleanup: cleanup_error(:cleanup_worker_failed),
            cleanup_job: nil,
            reap_deadline: now() + @reap_timeout_ms
        }
    after
      timeout -> state
    end
  end

  defp retain_output(state, chunk) do
    count = byte_size(chunk)
    retained = min(count, state.request.limit - state.retained)

    chunks =
      if retained > 0 do
        piece =
          if retained == count, do: chunk, else: :binary.copy(binary_part(chunk, 0, retained))

        [piece | state.chunks]
      else
        state.chunks
      end

    output_bytes = state.output_bytes + count

    %{
      state
      | chunks: chunks,
        retained: state.retained + retained,
        output_bytes: output_bytes,
        reason:
          state.reason || if(output_bytes > state.request.limit, do: "output_limit", else: nil)
    }
  end

  defp finished?(state) do
    state.cleanup != nil and port_finished?(state) and state.callback == nil and
      not state.scope_pending
  end

  defp port_finished?(state),
    do: state.port_closed or (state.eof and state.exit_status != nil)

  defp wait_time(state) do
    deadlines = [state.deadline, state.reap_deadline] |> Enum.reject(&is_nil/1)
    future = Enum.filter(deadlines, &(&1 > now()))
    if future == [], do: @poll_ms, else: min(@poll_ms, max(Enum.min(future) - now(), 0))
  end

  defp final_receipt(state) do
    finish_monitors(state)

    main_exit_status = state.cleanup["main_exit_status"] || state.receipt["main_exit_status"]
    command_started = state.cleanup["main_started"] == true or main_exit_status != nil

    keeper_timed_out = keeper_timed_out?(state)

    reason = state.reason || if(keeper_timed_out, do: "timed_out")
    status = reason || if(main_exit_status == 0, do: "passed", else: "failed")

    cleanup =
      state.cleanup
      |> Map.put("port_reaped", state.exit_status != nil)
      |> Map.put("port_closed", true)

    effect = final_effect(state, cleanup, main_exit_status, reason, command_started)
    error = final_error(state, cleanup, main_exit_status, reason)

    state
    |> snapshot_output()
    |> Map.put("status", status)
    |> Map.put("exit_status", main_exit_status)
    |> Map.put("launcher_exit_status", state.exit_status)
    |> Map.put("command_started", command_started)
    |> Map.put("cleanup", cleanup)
    |> Map.put("on_start", state.callback_status)
    |> Map.put("on_scope", state.scope_status)
    |> Map.put("effect", effect)
    |> Map.put("deadline_exceeded", state.deadline_exceeded or keeper_timed_out)
    |> Map.put("keeper_timed_out", keeper_timed_out)
    |> Map.put("cancellation", cancellation(state.cancel_requested, cleanup))
    |> maybe_error(error)
    |> finish_time(state.start)
  end

  defp finish_monitors(state) do
    close_port(state.port)
    Process.demonitor(state.port_monitor, [:flush])
    if state.owner_monitor != nil, do: Process.demonitor(elem(state.owner_monitor, 1), [:flush])
    {watchdog, token} = state.watchdog
    send(watchdog, {:finished, token})
  end

  defp keeper_timed_out?(state) do
    state.cleanup["keeper_timed_out"] == true or state.receipt["keeper_timed_out"] == true
  end

  defp final_effect(state, cleanup, main_exit_status, reason, command_started) do
    cond do
      cleanup["status"] == "not_started" and not command_started ->
        "not_started"

      reason == nil and cleanup["status"] == "confirmed" and
        main_exit_status != nil and state.exit_status != nil ->
        "completed"

      true ->
        "uncertain"
    end
  end

  defp final_error(state, cleanup, main_exit_status, reason) do
    state.error ||
      if main_exit_status == nil and reason == nil do
        cleanup["reason"] || "command_exit_status_unavailable"
      end
  end

  defp snapshot_output(state) do
    raw = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    incomplete = state.output_bytes > state.retained or not state.eof
    redacted = redact(raw, state.request.redactions, incomplete)
    sanitized = redacted |> valid_utf8() |> IO.iodata_to_binary()
    output = utf8_prefix(sanitized, state.request.limit)

    state.receipt
    |> Map.put(
      "args",
      Enum.map(state.request.argv, &safe_string(redact(&1, state.request.redactions, false)))
    )
    |> Map.put("output", output)
    |> Map.put("output_bytes", state.output_bytes)
    |> Map.put("output_complete", state.eof)
    |> Map.put("truncated", incomplete or byte_size(sanitized) > byte_size(output))
  end

  defp sample_resources(state) do
    if resource_sample_due?(state) do
      resources = state.receipt["resources"]
      resources = update_resource_sample(resources, sample_owned_resources(state.receipt))

      %{
        state
        | receipt: Map.put(state.receipt, "resources", resources),
          resource_next_sample: now() + @resource_interval_ms
      }
    else
      state
    end
  end

  defp resource_sample_due?(state) do
    state.receipt["process_identity"] != nil and state.reason == nil and state.exit_status == nil and
      not state.port_closed and now() >= state.resource_next_sample
  end

  defp update_resource_sample(resources, {:ok, sample}) do
    page_size = resources["page_size_bytes"]
    rss_bytes = if is_integer(page_size), do: sample.rss_pages * page_size, else: nil

    resources
    |> Map.put("status", "sampled")
    |> Map.update!("sample_count", &(&1 + 1))
    |> Map.put(
      "observed_peak_rss_bytes",
      maximum_known(resources["observed_peak_rss_bytes"], rss_bytes)
    )
    |> Map.put(
      "observed_peak_group_process_count",
      maximum_known(resources["observed_peak_group_process_count"], sample.process_count)
    )
    |> Map.put(
      "observed_cpu_ticks",
      maximum_known(resources["observed_cpu_ticks"], sample.cpu_ticks)
    )
  end

  defp update_resource_sample(resources, :empty), do: resources

  defp update_resource_sample(resources, {:error, reason}) do
    resources
    |> Map.update!("failed_sample_count", &(&1 + 1))
    |> Map.put("last_error", Atom.to_string(reason))
  end

  defp sample_owned_resources(receipt) do
    with {:ok, identity} <- receipt_identity(receipt),
         {:ok, _observed, members} <- observe_owned(receipt, identity),
         {:ok, sample} <- collect_resource_entries(members),
         :ok <- verify_leader(identity) do
      if sample.process_count > 0, do: {:ok, sample}, else: :empty
    end
  end

  defp collect_resource_entries(members) do
    deadline = now() + @resource_budget_ms
    initial = %{rss_pages: 0, cpu_ticks: 0, process_count: 0, inspected: 0}

    Enum.reduce_while(members, {:ok, initial}, &collect_resource_entry(&1, &2, deadline))
  end

  defp collect_resource_entry(member, {:ok, sample}, deadline) do
    cond do
      sample.inspected >= @resource_process_limit ->
        {:halt, {:error, :resource_process_scan_limit}}

      now() >= deadline ->
        {:halt, {:error, :resource_sample_budget}}

      true ->
        sample = %{sample | inspected: sample.inspected + 1}
        accumulate_resource_member(resource_member(member["pid"], member), sample)
    end
  end

  defp accumulate_resource_member({:ok, rss, cpu}, sample) do
    {:cont,
     {:ok,
      %{
        sample
        | rss_pages: sample.rss_pages + rss,
          cpu_ticks: sample.cpu_ticks + cpu,
          process_count: sample.process_count + 1
      }}}
  end

  defp accumulate_resource_member(:other, sample), do: {:cont, {:ok, sample}}

  defp accumulate_resource_member({:error, reason}, sample) when reason in [:enoent, :esrch],
    do: {:cont, {:ok, sample}}

  defp accumulate_resource_member({:error, _reason}, _sample) do
    {:halt, {:error, :resource_process_unreadable}}
  end

  defp resource_member(pid, identity) do
    case stat_fields(pid) do
      {:ok, [_, _, _, _ | _] = fields} -> resource_member_fields(fields, identity)
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_process_stat}
    end
  end

  defp resource_member_fields([state, _parent, group, session | _rest] = fields, identity) do
    if group == Integer.to_string(identity["process_group"]) and
         session == Integer.to_string(identity["session"]) and state not in ["Z", "X"] do
      resource_stat_values(fields, identity)
    else
      :other
    end
  end

  defp resource_stat_values(fields, identity) do
    with true <- Enum.at(fields, 19) == identity["start_time"],
         {user, ""} when user >= 0 <- Integer.parse(Enum.at(fields, 11)),
         {system, ""} when system >= 0 <- Integer.parse(Enum.at(fields, 12)),
         {rss, ""} when rss >= 0 <- Integer.parse(Enum.at(fields, 21)) do
      {:ok, rss, user + system}
    else
      _invalid -> {:error, :invalid_process_stat}
    end
  end

  defp initial_resources(basis) do
    %{
      "status" => "unknown",
      "sample_count" => 0,
      "failed_sample_count" => 0,
      "sample_interval_ms" => @resource_interval_ms,
      "sample_budget_ms" => @resource_budget_ms,
      "process_scan_limit" => @resource_process_limit,
      "observed_peak_rss_bytes" => nil,
      "observed_peak_group_process_count" => nil,
      "observed_cpu_ticks" => nil,
      "clock_ticks_per_second" => basis[:clock_ticks_per_second],
      "page_size_bytes" => basis[:page_size_bytes],
      "basis_source" => "/proc/self/auxv AT_CLKTCK and AT_PAGESZ",
      "peak_is_exact" => false,
      "cpu_accounting" =>
        "maximum sampled sum of live owned member utime + stime; excludes exited or unsampled members",
      "rss_accounting" =>
        "sampled owned-scope RSS sum; shared pages may be counted for multiple members",
      "process_scope" => "subreaper-owned processes across groups and sessions",
      "last_error" => nil
    }
  end

  defp resource_basis do
    case File.read("/proc/self/auxv") do
      {:ok, binary} -> auxv_basis(binary, :erlang.system_info(:wordsize) * 8, %{})
      {:error, _reason} -> %{}
    end
  end

  defp auxv_basis(binary, bits, basis) do
    case binary do
      <<key::unsigned-native-size(^bits), value::unsigned-native-size(^bits), rest::binary>> ->
        case key do
          0 ->
            basis

          6 when value > 0 ->
            auxv_basis(rest, bits, Map.put(basis, :page_size_bytes, value))

          17 when value > 0 ->
            auxv_basis(rest, bits, Map.put(basis, :clock_ticks_per_second, value))

          _other ->
            auxv_basis(rest, bits, basis)
        end

      _incomplete ->
        basis
    end
  end

  defp maximum_known(nil, value), do: value
  defp maximum_known(value, nil), do: value
  defp maximum_known(left, right), do: max(left, right)

  defp redact(binary, [], _incomplete), do: binary

  defp redact(binary, secrets, incomplete) do
    prefix = if incomplete, do: strip_secret_suffixes(binary, secrets), else: binary
    redacted = :binary.replace(prefix, :binary.compile_pattern(secrets), @redacted, [:global])

    if byte_size(prefix) < byte_size(binary), do: redacted <> @redacted, else: redacted
  end

  defp strip_secret_suffixes(binary, secrets) do
    suffix =
      Enum.reduce(secrets, 0, fn secret, longest ->
        max(longest, secret_suffix(binary, secret, min(byte_size(binary), byte_size(secret) - 1)))
      end)

    if suffix > 0 do
      # Recheck the shortened boundary: a second secret can overlap the part
      # just removed. Redacting complete matches first could expose its prefix.
      strip_secret_suffixes(binary_part(binary, 0, byte_size(binary) - suffix), secrets)
    else
      binary
    end
  end

  defp secret_suffix(_output, _secret, 0), do: 0

  defp secret_suffix(output, secret, size) do
    if binary_part(output, byte_size(output) - size, size) == binary_part(secret, 0, size) do
      size
    else
      secret_suffix(output, secret, size - 1)
    end
  end

  defp valid_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:error, valid, <<_invalid, rest::binary>>} -> [valid, "\uFFFD" | valid_utf8(rest)]
      {:incomplete, valid, _rest} -> [valid, "\uFFFD"]
    end
  end

  defp utf8_prefix(binary, limit) when byte_size(binary) <= limit, do: binary

  defp utf8_prefix(binary, limit) do
    case :unicode.characters_to_binary(binary_part(binary, 0, limit), :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
    end
  end

  defp recover_identity(receipt, deadline) do
    recorded = field(receipt, :launcher_identity)

    with nil <- field(receipt, :process_identity),
         boot when is_binary(boot) <- field(recorded, :boot_id),
         {:ok, current_boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         true <- String.trim(current_boot) == boot do
      case discover_identity(receipt, boot) do
        {:ok, identity} ->
          receipt
          |> Map.put("os_pid", identity["pid"])
          |> Map.put("process_identity", identity)

        {:error, _reason} ->
          retry_identity_recovery(receipt, deadline)
      end
    else
      _unavailable -> receipt
    end
  end

  defp retry_identity_recovery(receipt, deadline) do
    if now() < deadline and same_launcher?(receipt) do
      Process.sleep(@poll_ms)
      recover_identity(receipt, deadline)
    else
      receipt
    end
  end

  defp same_launcher?(receipt) do
    with pid when is_integer(pid) <- field(receipt, :launcher_pid),
         {:ok, current} <- read_process(pid) do
      current["start_time"] == field(field(receipt, :launcher_identity), :start_time) and
        current["state"] not in ["Z", "X"]
    else
      _unavailable -> false
    end
  end

  defp receipt_identity(receipt) do
    pid = field(receipt, :os_pid)
    identity = field(receipt, :process_identity)

    with true <- is_integer(pid) and pid > 1 and is_map(identity),
         true <- field(identity, :pid) == pid,
         true <- field(identity, :process_group) == pid and field(identity, :session) == pid,
         start when is_binary(start) <- field(identity, :start_time),
         {ticks, ""} when ticks >= 0 <- Integer.parse(start),
         boot when is_binary(boot) <- field(identity, :boot_id),
         {:ok, current_boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         true <- String.trim(current_boot) == boot do
      {:ok,
       %{
         "pid" => pid,
         "process_group" => pid,
         "session" => pid,
         "start_time" => start,
         "boot_id" => boot
       }}
    else
      _unverified -> {:error, :process_identity_unavailable}
    end
  end

  defp keeper_descriptor(receipt) do
    keeper = field(receipt, :process_keeper)

    with true <- is_map(keeper) and field(keeper, :schema) == 2,
         launch when is_binary(launch) <- field(receipt, :launch_id),
         true <- field(keeper, :launch_id) == launch,
         {:ok, ^launch} <- Ecto.UUID.cast(launch),
         path when is_binary(path) <- field(keeper, :status_path),
         true <- valid_string?(path) and Path.type(path) == :absolute,
         true <- Path.basename(path) == "status.json",
         true <- Path.basename(Path.dirname(path)) == launch,
         executable when is_binary(executable) <- field(keeper, :executable),
         script when is_binary(script) <- field(keeper, :script),
         true <- Path.type(executable) == :absolute and Path.type(script) == :absolute do
      {:ok, keeper}
    else
      _unverified -> {:error, :process_keeper_identity_unavailable}
    end
  end

  defp keeper_snapshot(receipt, identity) do
    with {:ok, keeper} <- keeper_descriptor(receipt),
         {:ok, status} <- read_keeper_status(field(keeper, :status_path)),
         true <- valid_keeper_status?(status, receipt, identity),
         {:ok, known} <- recorded_owned(status, identity),
         {:ok, _live} <- live_owned(status, known, identity) do
      observed =
        receipt
        |> merge_scope(status)
        |> Map.put("keeper_status", status["status"])
        |> Map.put("main_exit_status", status["main_exit_status"])
        |> Map.put("keeper_timed_out", status["timed_out"])
        |> Map.put("keeper_cancelled", status["cancelled"])

      {:ok, observed, status}
    else
      false -> {:error, :process_keeper_status_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp read_keeper_status(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @keeper_status_max_bytes,
         {:ok, device} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case :file.read(device, @keeper_status_max_bytes + 1) do
          {:ok, bytes} when byte_size(bytes) <= @keeper_status_max_bytes ->
            case Jason.decode(bytes) do
              {:ok, status} when is_map(status) -> {:ok, status}
              _invalid -> {:error, :process_keeper_status_invalid}
            end

          _unavailable ->
            {:error, :process_keeper_status_unavailable}
        end
      after
        File.close(device)
      end
    else
      _unavailable -> {:error, :process_keeper_status_unavailable}
    end
  end

  defp valid_keeper_status?(status, receipt, identity) do
    status["schema"] == 2 and status["launch_id"] == field(receipt, :launch_id) and
      valid_keeper_identity?(status["keeper_identity"], identity) and
      status["status"] in ["running", "settling", "settled", "uncertain"] and
      valid_keeper_main?(status, identity) and valid_keeper_scope?(status) and
      valid_keeper_cleanup?(status["cleanup"])
  end

  defp valid_keeper_identity?(keeper, identity) do
    is_map(keeper) and owned_key(keeper) == owned_key(identity) and
      keeper["process_group"] == identity["pid"] and keeper["session"] == identity["pid"]
  end

  defp valid_keeper_main?(status, identity) do
    main = status["main_identity"]
    main_exit_status = status["main_exit_status"]

    is_boolean(status["main_started"]) and is_boolean(status["timed_out"]) and
      (status["main_started"] or (main == nil and main_exit_status == nil)) and
      (main == nil or valid_owned?(main, identity)) and valid_main_exit_status?(main_exit_status)
  end

  defp valid_main_exit_status?(status) do
    status == nil or (is_integer(status) and status >= 0 and status <= 255)
  end

  defp valid_keeper_scope?(status) do
    is_boolean(status["cancelled"]) and is_boolean(status["scope_observed"]) and
      is_list(status["owned_processes"]) and is_boolean(status["owned_processes_complete"]) and
      is_list(status["live_processes"]) and status["live_processes"] != [] and
      (status["scope_error"] == nil or is_binary(status["scope_error"]))
  end

  defp valid_keeper_cleanup?(cleanup) do
    is_map(cleanup) and cleanup["authority"] == "linux_child_subreaper_waitpid" and
      cleanup["subreaper"] == true and is_boolean(cleanup["all_children_reaped"]) and
      cleanup["status"] in ["confirmed", "uncertain", "not_started"] and
      cleanup["term"] in ["sent", "not_needed"] and cleanup["kill"] in ["sent", "not_needed"]
  end

  defp await_keeper(receipt, identity, kill, deadline, requested) do
    case keeper_snapshot(receipt, identity) do
      {:ok, observed, status} ->
        await_keeper_status(observed, status, identity, kill, deadline, requested)

      {:error, reason} ->
        await_keeper_snapshot_error(receipt, identity, kill, deadline, requested, reason)
    end
  end

  defp await_keeper_status(receipt, status, identity, kill, deadline, requested) do
    cond do
      confirmed_keeper_settlement?(status) ->
        await_keeper_exit(receipt, status, identity, deadline)

      unstarted_keeper_settlement?(status) ->
        await_keeper_exit(receipt, status, identity, deadline)

      now() >= deadline or status["status"] in ["settled", "uncertain"] ->
        receipt
        |> keeper_cleanup(status)
        |> Map.put("status", "uncertain")
        |> Map.put("reason", keeper_settlement_failure(status))

      true ->
        requested = request_keeper_stop(identity, kill, requested)
        Process.sleep(@poll_ms)
        await_keeper(receipt, identity, kill, deadline, requested)
    end
  end

  defp confirmed_keeper_settlement?(status) do
    cleanup = status["cleanup"]

    status["status"] == "settled" and cleanup["status"] == "confirmed" and
      cleanup["all_children_reaped"] == true and status["main_started"] == true and
      is_integer(status["main_exit_status"])
  end

  defp unstarted_keeper_settlement?(status) do
    status["status"] == "settled" and status["cleanup"]["status"] == "not_started" and
      status["main_started"] == false and status["main_identity"] == nil and
      status["main_exit_status"] == nil
  end

  defp keeper_settlement_failure(status) do
    case status["status"] do
      "uncertain" -> status["cleanup"]["reason"] || "process_keeper_settlement_unconfirmed"
      "settled" -> "process_keeper_settlement_invalid"
      _unsettled -> "process_keeper_settlement_deadline"
    end
  end

  defp request_keeper_stop(identity, kill, requested) do
    if not requested and live_listener_leader?(identity) do
      signal_process(kill, "TERM", Integer.to_string(identity["pid"]))
      true
    else
      requested
    end
  end

  defp await_keeper_snapshot_error(receipt, identity, kill, deadline, requested, reason) do
    if now() >= deadline do
      merge_scope(cleanup_error(reason), receipt)
    else
      case verify_leader(identity) do
        :ok ->
          Process.sleep(@poll_ms)
          await_keeper(receipt, identity, kill, deadline, requested)

        {:error, reason} ->
          merge_scope(cleanup_error(reason), receipt)
      end
    end
  end

  defp await_keeper_exit(receipt, status, identity, deadline) do
    case read_process(identity["pid"]) do
      {:ok, current} ->
        await_live_keeper_exit(receipt, status, identity, deadline, current)

      {:error, reason} when reason in [:enoent, :esrch] ->
        receipt |> keeper_cleanup(status) |> Map.put("keeper_terminated", true)

      {:error, _reason} ->
        merge_scope(cleanup_error(:process_keeper_identity_unreadable), receipt)
    end
  end

  defp await_live_keeper_exit(receipt, status, identity, deadline, current) do
    cond do
      current["state"] in ["Z", "X"] or current["start_time"] != identity["start_time"] ->
        receipt |> keeper_cleanup(status) |> Map.put("keeper_terminated", true)

      current["process_group"] != identity["pid"] or current["session"] != identity["pid"] ->
        merge_scope(cleanup_error(:process_identity_changed), receipt)

      now() >= deadline ->
        receipt
        |> keeper_cleanup(status)
        |> Map.put("status", "uncertain")
        |> Map.put("reason", "process_keeper_still_running")
        |> Map.put("keeper_terminated", false)

      true ->
        Process.sleep(@poll_ms)
        await_keeper_exit(receipt, status, identity, deadline)
    end
  end

  defp keeper_cleanup(receipt, status) do
    status["cleanup"]
    |> Map.put("identity_verified", true)
    |> Map.put("keeper_status", status["status"])
    |> Map.put("main_exit_status", status["main_exit_status"])
    |> Map.put("main_started", status["main_started"])
    |> Map.put("keeper_timed_out", status["timed_out"])
    |> Map.put("keeper_cancelled", status["cancelled"])
    |> merge_scope(receipt)
  end

  defp observe_owned(receipt, identity) do
    deadline = now() + @scope_budget_ms

    with :ok <- verify_leader(identity),
         {:ok, observed, status} <- keeper_snapshot(receipt, identity),
         {:ok, recorded} <- recorded_owned(observed, identity),
         {:ok, current} <- refresh_owned(status["live_processes"], identity["boot_id"], deadline),
         :ok <- verify_leader(identity) do
      known =
        Enum.reduce(current, recorded, fn member, known ->
          Map.put(
            known,
            owned_key(member, identity["boot_id"]),
            owned_identity(member, identity["boot_id"])
          )
        end)

      observed = Map.put(observed, "owned_processes", sorted_owned(known))
      {:ok, observed, Enum.reject(current, &(&1["state"] in ["Z", "X"]))}
    end
  end

  defp recorded_owned(receipt, identity) do
    recorded = field(receipt, :owned_processes) || []

    if is_list(recorded) and length(recorded) <= @owned_process_limit do
      Enum.reduce_while(
        recorded,
        {:ok, %{owned_key(identity) => identity}},
        &record_owned_process(&1, &2, identity)
      )
    else
      {:error, :owned_process_limit}
    end
  end

  defp live_owned(status, recorded, identity) do
    with {:ok, live} <-
           recorded_owned(%{"owned_processes" => status["live_processes"]}, identity),
         true <- Enum.all?(live, fn {key, _member} -> Map.has_key?(recorded, key) end) do
      {:ok, live}
    else
      false -> {:error, :invalid_live_process_identity}
      {:error, _reason} = error -> error
    end
  end

  defp record_owned_process(member, {:ok, known}, identity) do
    if valid_owned?(member, identity) do
      member = owned_identity(member, identity["boot_id"])
      {:cont, {:ok, Map.put(known, owned_key(member), member)}}
    else
      {:halt, {:error, :invalid_owned_process_identity}}
    end
  end

  defp valid_owned?(member, identity) do
    start = field(member, :start_time)

    is_map(member) and is_integer(field(member, :pid)) and field(member, :pid) > 1 and
      field(member, :boot_id) == identity["boot_id"] and valid_owned_start?(start, identity) and
      valid_owned_scope?(member)
  end

  defp valid_owned_start?(start, identity) do
    is_binary(start) and match?({ticks, ""} when ticks >= 0, Integer.parse(start)) and
      String.to_integer(start) >= String.to_integer(identity["start_time"])
  end

  defp valid_owned_scope?(member) do
    is_integer(field(member, :process_group)) and field(member, :process_group) > 0 and
      is_integer(field(member, :session)) and field(member, :session) > 0
  end

  defp refresh_owned(recorded, boot_id, deadline) do
    Enum.reduce_while(recorded, {:ok, []}, &refresh_owned_member(&1, &2, boot_id, deadline))
  end

  defp refresh_owned_member(member, {:ok, current}, boot_id, deadline) do
    if now() >= deadline do
      {:halt, {:error, :ownership_refresh_deadline}}
    else
      refresh_owned_result(read_process(member["pid"]), member, current, boot_id)
    end
  end

  defp refresh_owned_result({:ok, observed}, member, current, boot_id) do
    if owned_key(observed, boot_id) == owned_key(member),
      do: {:cont, {:ok, [observed | current]}},
      else: {:cont, {:ok, current}}
  end

  defp refresh_owned_result({:error, reason}, _member, current, _boot_id)
       when reason in [:enoent, :esrch],
       do: {:cont, {:ok, current}}

  defp refresh_owned_result({:error, _reason}, _member, _current, _boot_id) do
    {:halt, {:error, :ownership_process_unreadable}}
  end

  defp owned_identity(member, boot) do
    member
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(~w(pid start_time process_group session parent_pid))
    |> Map.put("boot_id", boot)
  end

  defp owned_key(member, boot \\ nil),
    do: {field(member, :pid), field(member, :start_time), boot || field(member, :boot_id)}

  defp sorted_owned(known),
    do: known |> Map.values() |> Enum.sort_by(&owned_key/1)

  defp merge_owned(left, right) do
    ((field(left, :owned_processes) || []) ++ (field(right, :owned_processes) || []))
    |> Map.new(&{owned_key(&1), &1})
    |> sorted_owned()
  end

  defp merge_scope(receipt, observed) do
    owned = merge_owned(receipt, observed)
    overflow = length(owned) > @owned_process_limit

    owned =
      if overflow do
        identity = field(receipt, :process_identity) || field(observed, :process_identity)
        {leader, descendants} = Enum.split_with(owned, &(owned_key(&1) == owned_key(identity)))

        (leader ++ descendants)
        |> Enum.take(@owned_process_limit)
        |> Enum.sort_by(&owned_key/1)
      else
        owned
      end

    receipt
    |> Map.put("owned_processes", owned)
    |> Map.put(
      "scope_observed",
      field(receipt, :scope_observed) == true or field(observed, :scope_observed) == true
    )
    |> Map.put(
      "owned_processes_complete",
      field(receipt, :owned_processes_complete) != false and
        field(observed, :owned_processes_complete) != false and not overflow
    )
    |> Map.put(
      "scope_error",
      field(receipt, :scope_error) || field(observed, :scope_error) ||
        if(overflow, do: "owned_process_limit", else: nil)
    )
  end

  defp scope_changed?(left, right) do
    Enum.any?(
      ~w(
        owned_processes scope_observed owned_processes_complete scope_error
        keeper_status main_exit_status keeper_timed_out keeper_cancelled
      ),
      fn key -> Map.get(left, key) != Map.get(right, key) end
    )
  end

  defp incomplete_scope(receipt, reason) do
    receipt
    |> Map.put("owned_processes_complete", false)
    |> Map.put("scope_error", field(receipt, :scope_error) || Atom.to_string(reason))
  end

  defp verify_leader(identity) do
    case read_process(identity["pid"]) do
      {:ok, current} ->
        if current["start_time"] == identity["start_time"] and
             current["process_group"] == identity["pid"] and current["session"] == identity["pid"] do
          :ok
        else
          {:error, :process_identity_changed}
        end

      {:error, reason} when reason in [:enoent, :esrch] ->
        :ok

      {:error, _reason} ->
        {:error, :process_identity_unreadable}
    end
  end

  defp signal_process(kill, signal, target) do
    case open_port(kill, ["-#{signal}", "--", target], "/", %{}) do
      {:ok, port, _pid, monitor} ->
        result = await_signal(port, monitor, now() + @signal_timeout_ms)
        close_port(port)
        Process.demonitor(monitor, [:flush])
        result

      {:error, _reason} ->
        "failed"
    end
  end

  defp await_signal(port, monitor, deadline) do
    receive do
      {^port, {:data, _discarded}} -> await_signal(port, monitor, deadline)
      {^port, :eof} -> await_signal(port, monitor, deadline)
      {^port, {:exit_status, 0}} -> "sent"
      {^port, {:exit_status, _status}} -> "failed"
      {:DOWN, ^monitor, :port, ^port, _reason} -> "uncertain"
    after
      max(deadline - now(), 0) -> "uncertain"
    end
  end

  defp stop_launcher(receipt, deadline) do
    pid = field(receipt, :launcher_pid)
    recorded = field(receipt, :launcher_identity)

    with true <- is_integer(pid) and pid > 1 and is_map(recorded),
         {:ok, boot_id} <- File.read("/proc/sys/kernel/random/boot_id"),
         true <- String.trim(boot_id) == field(recorded, :boot_id),
         {:ok, current} <- read_process(pid),
         true <- current["start_time"] == field(recorded, :start_time),
         {:ok, kill} <- receipt_kill(receipt) do
      settle_launcher(receipt, pid, recorded, current, kill, deadline)
    else
      {:error, reason} when reason in [:enoent, :esrch] -> "already_exited"
      _unverified -> "unverified"
    end
  end

  defp settle_launcher(receipt, pid, recorded, current, kill, deadline) do
    cond do
      now() < deadline and current["state"] not in ["Z", "X"] ->
        Process.sleep(@poll_ms)
        stop_launcher(receipt, deadline)

      current["state"] in ["Z", "X"] ->
        "already_exited"

      true ->
        signal_process(kill, "KILL", Integer.to_string(pid))
        await_launcher_exit(pid, recorded, now() + @term_grace_ms)
    end
  end

  defp await_launcher_exit(pid, recorded, deadline) do
    case read_process(pid) do
      {:ok, current} ->
        cond do
          current["state"] in ["Z", "X"] or
              current["start_time"] != field(recorded, :start_time) ->
            "terminated"

          now() >= deadline ->
            "uncertain"

          true ->
            Process.sleep(@poll_ms)
            await_launcher_exit(pid, recorded, deadline)
        end

      {:error, reason} when reason in [:enoent, :esrch] ->
        "terminated"

      {:error, _reason} ->
        "unverified"
    end
  end

  defp read_process(pid) do
    with {:ok, [state, parent, group, session | _rest] = values} <- stat_fields(pid),
         start when is_binary(start) <- Enum.at(values, 19),
         {parent, ""} <- Integer.parse(parent),
         {group, ""} <- Integer.parse(group),
         {session, ""} <- Integer.parse(session) do
      {:ok,
       %{
         "pid" => pid,
         "state" => state,
         "parent_pid" => parent,
         "process_group" => group,
         "session" => session,
         "start_time" => start
       }}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_process_stat}
    end
  end

  defp stat_fields(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_all, fields] <- Regex.run(~r/^\d+ \(.*\) (.*)$/s, stat) do
      {:ok, String.split(fields)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_process_stat}
    end
  end

  defp cleanup_error(reason) do
    %{
      "status" => "uncertain",
      "identity_verified" => false,
      "term" => "not_sent",
      "kill" => "not_sent",
      "remaining" => [],
      "reason" => Atom.to_string(reason)
    }
  end

  defp initial_receipt(executable, argv, cwd, started_at) do
    %{
      "status" => "unavailable",
      "exit_status" => nil,
      "launcher_exit_status" => nil,
      "command_started" => false,
      "dispatch" => "not_started",
      "output" => "",
      "output_bytes" => 0,
      "output_complete" => false,
      "truncated" => false,
      "os_pid" => nil,
      "process_identity" => nil,
      "owned_processes" => [],
      "scope_observed" => false,
      "owned_processes_complete" => true,
      "scope_error" => nil,
      "started_at" => started_at,
      "finished_at" => nil,
      "duration_ms" => 0,
      "executable" => safe_string(executable),
      "args" =>
        if(is_list(argv) and Enum.all?(argv, &is_binary/1),
          do: Enum.map(argv, &safe_string/1),
          else: []
        ),
      "cwd" => safe_string(cwd),
      "deadline_exceeded" => false,
      "cancellation" => "not_requested",
      "effect" => "not_started",
      "resources" => initial_resources(%{}),
      "timeout_ms" => nil,
      "max_output_bytes" => nil,
      "cleanup" => %{"status" => "not_started"}
    }
  end

  defp put_limits(receipt, opts) do
    timeout = option(opts, :timeout_ms) || @default_timeout_ms
    output = option(opts, :max_output_bytes) || @default_output_bytes

    receipt
    |> Map.put("timeout_ms", if(is_integer(timeout), do: timeout, else: nil))
    |> Map.put("max_output_bytes", if(is_integer(output), do: output, else: nil))
  end

  defp cancellation(true, cleanup), do: cleanup["status"]
  defp cancellation(false, _cleanup), do: "not_requested"
  defp maybe_error(receipt, nil), do: receipt
  defp maybe_error(receipt, error), do: Map.put(receipt, "error", error)

  defp finish_time(receipt, start) do
    receipt
    |> Map.put("finished_at", timestamp())
    |> Map.put("duration_ms", max(now() - start, 0))
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp field(map, key) when is_map(map), do: Map.get(map, Atom.to_string(key), Map.get(map, key))
  defp field(_map, _key), do: nil

  defp option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key), else: nil
  end

  defp option(_opts, _key), do: nil

  defp safe_string(value) when is_binary(value),
    do: value |> valid_utf8() |> IO.iodata_to_binary()

  defp safe_string(_value), do: nil

  defp valid_string?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp now, do: System.monotonic_time(:millisecond)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
