defmodule OhMyJido.Process do
  @moduledoc """
  Host-authorized Linux subprocesses owned by the calling OTP process.

  `run/4` waits for a command; `start/4` returns an opaque cancellation handle.
  `await/2` is called by that handle's owner. Killing the owner also cancels the
  command. No VM working directory or environment is changed. Linux `setsid`,
  `sh`, `mkfifo`, `cat` and `kill` must be installed; unsupported hosts fail closed.

  Options are `:cwd` (workspace-relative), `:env` (child overrides, nil unsets),
  `:timeout` (milliseconds), `:max_output_bytes` (per stream), `:kill_grace_ms`,
  `:on_output` (recipient PID or a two-argument function), and an optional
  `:observer` PID receiving the final result. Streaming and retention share the
  same byte cap; excess bytes are drained without being retained. Function
  callbacks run in the owner during `await/2`, not in the resource-cleanup task.

  Trusted host integrations may select `:capability` and add `:effect` metadata.
  The model-facing Shell Action never forwards these authority overrides.

  Results preserve raw stdout/stderr, exit status, duration and truncation.
  `cleanup: :confirmed` means no live member of the owned process group remains;
  zombies are not running processes. Interrupted effects remain `:uncertain`,
  even with confirmed cleanup: killing a process cannot undo its earlier writes.
  This is lifecycle confinement, not an OS sandbox. Deliberate daemonization or
  process-group escape requires a host sandbox/cgroup policy.
  """

  alias OhMyJido.{Context, Runtime, Tool, Workspace}

  defmodule Handle do
    @moduledoc "An opaque, caller-owned handle returned by `OhMyJido.Process.start/4`."
    @enforce_keys [:pid, :ref, :monitor, :owner]
    defstruct [:pid, :ref, :monitor, :owner, :on_output, :coordinator]

    @type t :: %__MODULE__{
            pid: pid(),
            ref: reference(),
            monitor: reference(),
            owner: pid(),
            on_output: term(),
            coordinator: pid() | nil
          }
  end

  @launcher """
  printf 'omj:%s\\n' "$$"
  IFS= read -r ready || exit 125
  [ "$ready" = go ] || exit 125
  out=$1; err=$2; shift 2
  exec "$@" </dev/null >"$out" 2>"$err"
  """
  @helpers ["setsid", "sh", "mkfifo", "cat", "kill"]
  @default_timeout 30_000
  @default_output 1_048_576
  @cleanup_timeout 2_000
  @poll_ms 20

  @doc "Runs one approved command with separate streams and a child deadline."
  @spec run(map() | Context.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(context, executable, args, opts \\ []) do
    with {:ok, handle} <- start(context, executable, args, opts) do
      await(handle)
    end
  end

  @doc "Starts an approved command without linking its cleanup task to the caller."
  @spec start(map() | Context.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  def start(execution_context, executable, args, opts \\ []) do
    with {:ok, context} <- Context.fetch(execution_context),
         {:ok, request} <- prepare(context, executable, args, opts),
         :ok <- Tool.authorize(context, request.capability, request.effect) do
      start_approved(context, request)
    end
  end

  defp start_approved(context, request) do
    owner = self()
    ref = make_ref()

    {:ok, pid} = Task.start(fn -> own_command(owner, ref, context, request) end)
    await_start(context, request, owner, ref, pid)
  end

  defp await_start(context, request, owner, ref, pid) do
    monitor = Elixir.Process.monitor(pid)

    handle = %Handle{
      pid: pid,
      ref: ref,
      monitor: monitor,
      owner: owner,
      on_output: request.on_output,
      coordinator: context.coordinator
    }

    send(pid, {:activate, ref, handle})

    receive do
      {:oh_my_jido_process_start, ^ref, :ok} ->
        {:ok, handle}

      {:oh_my_jido_process_start, ^ref, {:error, _reason} = error} ->
        Elixir.Process.demonitor(monitor, [:flush])
        error

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:process_start_failed, reason}}
    end
  end

  @doc "Waits for the owner handle's result; an await timeout does not replay or cancel the effect."
  @spec await(Handle.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(handle, timeout \\ :infinity)

  def await(%Handle{owner: owner} = handle, timeout) when owner == self() do
    deadline = if timeout == :infinity, do: :infinity, else: now() + timeout
    await_result(handle, deadline)
  end

  def await(%Handle{}, _timeout), do: {:error, :not_process_owner}

  @doc "Cancels the whole owned group and returns its observed cleanup and effect outcome."
  @spec cancel(Handle.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Handle{pid: pid, ref: ref}) do
    reply = make_ref()
    monitor = Elixir.Process.monitor(pid)
    send(pid, {:cancel, ref, self(), reply})

    receive do
      {^reply, result} ->
        Elixir.Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :not_running}
    after
      @cleanup_timeout + 5_000 ->
        Elixir.Process.demonitor(monitor, [:flush])
        {:error, %{reason: :cancellation_unconfirmed, effect: :uncertain, cleanup: :uncertain}}
    end
  end

  @doc "Captures Linux start/group/session identity for a trusted, already-authorized Port owner."
  @spec capture_identity(pos_integer()) :: {:ok, map()} | {:error, term()}
  def capture_identity(pid) when is_integer(pid) and pid > 0, do: process_identity(pid)
  def capture_identity(_pid), do: {:error, :invalid_process_identity}

  @doc "Terminates an owned session leader's group without signaling a reused PID."
  @spec terminate_group(pos_integer(), map()) :: :ok | {:error, :cleanup_uncertain}
  def terminate_group(pid, %{group: group, session: session, start: start} = identity)
      when is_integer(pid) and pid > 0 and is_binary(group) and is_binary(session) and
             is_binary(start) do
    with true <- group == Integer.to_string(pid) and session == group,
         kill when is_binary(kill) <- System.find_executable("kill"),
         :ok <- signal_group(kill, pid, identity, "KILL") do
      await_group_cleanup(pid, identity, now() + @cleanup_timeout)
    else
      _unconfirmed -> {:error, :cleanup_uncertain}
    end
  end

  def terminate_group(_pid, _identity), do: {:error, :cleanup_uncertain}

  defp await_group_cleanup(pid, identity, deadline) do
    cond do
      group_empty?(pid, identity) ->
        :ok

      now() >= deadline ->
        {:error, :cleanup_uncertain}

      true ->
        Elixir.Process.sleep(@poll_ms)
        await_group_cleanup(pid, identity, deadline)
    end
  end

  defp await_result(handle, deadline) do
    receive do
      {:oh_my_jido_process, ref, result} when ref == handle.ref ->
        Elixir.Process.demonitor(handle.monitor, [:flush])
        flush_output(handle)
        result

      {:oh_my_jido_process_output, ref, stream, data}
      when ref == handle.ref and is_function(handle.on_output, 2) ->
        deliver_callback(handle.on_output, stream, data)
        await_result(handle, deadline)

      {:DOWN, monitor, :process, pid, reason}
      when monitor == handle.monitor and pid == handle.pid ->
        {:error,
         %{reason: {:process_worker_down, reason}, effect: :uncertain, cleanup: :uncertain}}
    after
      remaining(deadline) -> {:error, :await_timeout}
    end
  end

  defp flush_output(%Handle{coordinator: coordinator, ref: ref})
       when is_pid(coordinator) and coordinator != self() do
    OhMyJido.Session.call(coordinator, {:flush_process_output, ref})
  end

  defp flush_output(_handle), do: :ok

  defp deliver_callback(callback, stream, data) when is_function(callback, 2) do
    callback.(stream, data)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp prepare(context, executable, args, opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- valid_string?(executable) and executable != "",
         true <- is_list(args) and Enum.all?(args, &valid_string?/1),
         {:ok, cwd} <- Workspace.resolve(context, Keyword.get(opts, :cwd, ".")),
         true <- File.dir?(cwd),
         {:ok, executable} <- executable_path(executable, cwd),
         {:ok, env} <- child_environment(Keyword.get(opts, :env, %{})),
         {:ok, helpers} <- helpers(),
         {:ok, limits} <- limits(context, opts),
         capability when is_atom(capability) and not is_nil(capability) <-
           Keyword.get(opts, :capability, :exec),
         effect when is_map(effect) <- Keyword.get(opts, :effect, %{}),
         true <- valid_recipient?(Keyword.get(opts, :on_output)),
         true <- is_nil(Keyword.get(opts, :observer)) or is_pid(Keyword.get(opts, :observer)),
         true <-
           is_nil(Keyword.get(opts, :before_effect)) or
             is_function(Keyword.get(opts, :before_effect), 0) do
      effect =
        Map.merge(effect, %{executable: executable, args: args, cwd: cwd, env: Map.new(env)})

      {:ok,
       Map.merge(limits, %{
         executable: executable,
         args: args,
         cwd: cwd,
         env: env,
         helpers: helpers,
         capability: capability,
         effect: effect,
         on_output: Keyword.get(opts, :on_output),
         observer: Keyword.get(opts, :observer),
         context: context,
         before_effect: Keyword.get(opts, :before_effect)
       })}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_process_request}
    end
  end

  defp valid_string?(value), do: is_binary(value) and not String.contains?(value, <<0>>)
  defp valid_recipient?(value), do: is_nil(value) or is_pid(value) or is_function(value, 2)

  defp executable_path(executable, cwd) do
    candidate =
      if String.contains?(executable, "/"), do: Path.expand(executable, cwd), else: executable

    case System.find_executable(candidate) do
      nil -> {:error, {:executable_not_found, executable}}
      path -> {:ok, path}
    end
  end

  defp child_environment(env) when is_map(env), do: child_environment(Map.to_list(env))

  defp child_environment(env) when is_list(env) do
    if Enum.all?(env, fn
         {key, value} ->
           valid_string?(key) and key != "" and not String.contains?(key, "=") and
             (is_nil(value) or valid_string?(value))

         _invalid ->
           false
       end) do
      {:ok, env}
    else
      {:error, :invalid_process_environment}
    end
  end

  defp child_environment(_env), do: {:error, :invalid_process_environment}

  defp helpers do
    if :os.type() == {:unix, :linux} and File.dir?("/proc") do
      Enum.reduce_while(@helpers, {:ok, %{}}, &find_helper/2)
    else
      {:error, {:capability_unavailable, :linux_process_groups}}
    end
  end

  defp find_helper(name, {:ok, found}) do
    case System.find_executable(name) do
      nil -> {:halt, {:error, {:capability_unavailable, {:process_executable, name}}}}
      path -> {:cont, {:ok, Map.put(found, name, path)}}
    end
  end

  defp limits(context, opts) do
    ceiling =
      Map.get(
        context.limits,
        :process_timeout_ms,
        Map.get(context.limits, :tool_timeout_ms, @default_timeout)
      )

    output_ceiling = Map.get(context.limits, :max_output_bytes, @default_output)
    timeout = Keyword.get(opts, :timeout, ceiling)
    cap = Keyword.get(opts, :max_output_bytes, output_ceiling)
    grace = Keyword.get(opts, :kill_grace_ms, 100)

    if valid_timeouts?(timeout, ceiling) and valid_output_limits?(cap, output_ceiling) and
         is_integer(grace) and grace in 0..5_000 do
      {:ok, %{timeout: min(timeout, ceiling), cap: min(cap, output_ceiling), grace: grace}}
    else
      {:error, :invalid_process_limits}
    end
  end

  defp valid_timeouts?(timeout, ceiling),
    do: is_integer(timeout) and timeout > 0 and is_integer(ceiling) and ceiling > 0

  defp valid_output_limits?(cap, ceiling),
    do: is_integer(cap) and cap >= 0 and is_integer(ceiling) and ceiling >= 0

  defp own_command(owner, ref, context, request) do
    Elixir.Process.flag(:trap_exit, true)
    owner_monitor = Elixir.Process.monitor(owner)

    coordinator_monitor =
      if context.coordinator, do: Elixir.Process.monitor(context.coordinator), else: nil

    request = Map.put(request, :coordinator_monitor, coordinator_monitor)

    try do
      case activation(owner, owner_monitor, ref) do
        {:ok, handle} -> reserve_owned(owner, owner_monitor, ref, context, request, handle)
        {:error, _reason} = error -> send(owner, {:oh_my_jido_process_start, ref, error})
      end
    after
      Elixir.Process.demonitor(owner_monitor, [:flush])
      if coordinator_monitor, do: Elixir.Process.demonitor(coordinator_monitor, [:flush])
    end
  end

  defp reserve_owned(owner, owner_monitor, ref, context, request, handle) do
    case Runtime.reserve(context.runtime, :process, self()) do
      {:ok, lease} ->
        lease_monitor = if lease, do: Elixir.Process.monitor(lease)

        try do
          execute_registered(owner, owner_monitor, ref, context, request, handle, lease_monitor)
        after
          Runtime.release(lease)
          if lease_monitor, do: Elixir.Process.demonitor(lease_monitor, [:flush])
        end

      {:error, _reason} = error ->
        send(owner, {:oh_my_jido_process_start, ref, error})
    end
  end

  defp execute_registered(owner, owner_monitor, ref, context, request, handle, lease_monitor) do
    case register_resource(context, handle) do
      {:ok, key} ->
        outcome =
          execute_owned(
            owner,
            owner_monitor,
            ref,
            Map.put(request, :lease_monitor, lease_monitor)
          )

        unregister_resource(context, key, outcome)
        outcome

      {:error, _reason} = error ->
        send(owner, {:oh_my_jido_process_start, ref, error})
    end
  end

  defp activation(owner, owner_monitor, ref) do
    receive do
      {:activate, ^ref, %Handle{owner: ^owner, pid: pid} = handle} when pid == self() ->
        {:ok, handle}

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        {:error, :process_owner_down}
    end
  end

  defp register_resource(%Context{coordinator: nil}, _handle), do: {:ok, nil}

  defp register_resource(context, handle) do
    OhMyJido.Session.register_resource(context.coordinator, context.run_id, :process, handle)
  catch
    :exit, _reason -> {:error, :coordinator_unavailable}
  end

  defp unregister_resource(_context, nil, _outcome), do: :ok

  defp unregister_resource(context, key, {:ok, %{cleanup: :confirmed}}),
    do: unregister_resource(context, key)

  defp unregister_resource(context, key, {:error, _reason}), do: unregister_resource(context, key)
  defp unregister_resource(_context, _key, _uncertain), do: :ok

  defp unregister_resource(context, key) do
    OhMyJido.Session.unregister_resource(context.coordinator, key)
  catch
    :exit, _reason -> :ok
  end

  defp execute_owned(owner, owner_monitor, ref, request) do
    case private_pipes(request.helpers["mkfifo"]) do
      {:ok, directory, stdout, stderr} ->
        try do
          launch(owner, owner_monitor, ref, request, stdout, stderr)
        after
          File.rm_rf(directory)
        end

      {:error, _reason} = error ->
        send(owner, {:oh_my_jido_process_start, ref, error})
        error
    end
  end

  defp private_pipes(mkfifo) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "oh-my-jido-process-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    stdout = Path.join(directory, "stdout")
    stderr = Path.join(directory, "stderr")

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         {_output, 0} <-
           System.cmd(mkfifo, ["--mode=600", "--", stdout, stderr], stderr_to_stdout: true) do
      {:ok, directory, stdout, stderr}
    else
      error ->
        File.rm_rf(directory)
        {:error, {:process_pipes_failed, error}}
    end
  end

  defp launch(owner, owner_monitor, ref, request, stdout, stderr) do
    outcome =
      with_reader(request, stdout, fn stdout_port ->
        with_reader(request, stderr, fn stderr_port ->
          args = [
            "--wait",
            "--",
            request.helpers["sh"],
            "-c",
            @launcher,
            "oh-my-jido",
            stdout,
            stderr,
            request.executable | request.args
          ]

          env = Enum.map(request.env, &environment_entry/1)

          with_launcher(owner, owner_monitor, ref, request, args, env, stdout_port, stderr_port)
        end)
      end)

    case outcome do
      {:ok, completed} ->
        send(owner, {:oh_my_jido_process, ref, {:ok, completed.result}})

        if request.observer && request.observer != owner,
          do: send(request.observer, {:oh_my_jido_process, ref, {:ok, completed.result}})

        Enum.each(completed.waiters, fn {pid, reply} ->
          send(pid, {reply, {:ok, completed.result}})
        end)

        {:ok, completed.result}

      {:error, _reason} = error ->
        send(owner, {:oh_my_jido_process_start, ref, error})
        error
    end
  end

  defp environment_entry({key, value}) do
    {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
  end

  defp with_launcher(owner, owner_monitor, ref, request, args, env, stdout_port, stderr_port) do
    case open_launcher(request, args, env) do
      {:ok, child} ->
        try do
          launch_controller(
            owner,
            owner_monitor,
            ref,
            request,
            child.port,
            stdout_port,
            stderr_port
          )
        after
          close_port(child, request.helpers["kill"])
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp with_reader(request, path, callback) do
    case open_port(request.helpers["cat"], ["--", path], []) do
      {:ok, child} ->
        try do
          callback.(child.port)
        after
          close_port(child, request.helpers["kill"])
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp open_launcher(request, args, env) do
    with {:ok, cwd} <- Workspace.resolve(request.context, request.cwd),
         true <- cwd == request.cwd and File.dir?(cwd) do
      open_port(request.helpers["setsid"], args, cd: String.to_charlist(cwd), env: env)
    else
      {:error, _reason} = error -> error
      _changed -> {:error, :process_directory_changed}
    end
  end

  defp before_effect(nil), do: :ok

  defp before_effect(callback) do
    case callback.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_process_precondition}
    end
  rescue
    _error -> {:error, :process_precondition_failed}
  end

  defp launch_controller(owner, owner_monitor, ref, request, controller, stdout_port, stderr_port) do
    with {:ok, pid, identity} <-
           leader(controller, owner_monitor, now() + min(request.timeout, 5_000), "") do
      state = %{
        owner: owner,
        owner_monitor: owner_monitor,
        coordinator_monitor: request.coordinator_monitor,
        lease_monitor: request.lease_monitor,
        ref: ref,
        request: request,
        controller: controller,
        ports: %{controller => :control, stdout_port => :stdout, stderr_port => :stderr},
        pid: pid,
        identity: identity,
        start: now(),
        deadline: now() + request.timeout,
        status: :running,
        exit_status: nil,
        eof: %{},
        chunks: %{stdout: [], stderr: []},
        retained: %{stdout: 0, stderr: 0},
        output_bytes: %{stdout: 0, stderr: 0},
        stopping_at: nil,
        kill_sent: false,
        waiters: [],
        cleanup_error: false,
        background_cleanup: false,
        execution_started: false
      }

      try do
        with :ok <- before_effect(request.before_effect),
             true <- now() < state.deadline do
          state = startup_control(state)
          if state.status == :running, do: Port.command(controller, "go\n")
          send(owner, {:oh_my_jido_process_start, ref, :ok})
          {:ok, collect(%{state | execution_started: state.status == :running})}
        else
          {:error, _reason} = error -> error
          false -> {:error, :process_precondition_timeout}
        end
      after
        signal_group(request.helpers["kill"], pid, identity, "KILL")
      end
    end
  end

  defp startup_control(state) do
    receive do
      {:cancel, ref, requester, reply} when ref == state.ref ->
        stop(%{state | waiters: [{requester, reply} | state.waiters]}, :cancelled)

      {:DOWN, monitor, :process, _pid, _reason}
      when monitor == state.owner_monitor or monitor == state.coordinator_monitor or
             monitor == state.lease_monitor ->
        stop(state, :owner_down)
    after
      0 -> state
    end
  end

  defp open_port(executable, args, opts) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :eof,
        :hide,
        :stderr_to_stdout,
        {:args, args} | opts
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    identity =
      case process_identity(pid) do
        {:ok, identity} -> identity
        {:error, _reason} -> nil
      end

    {:ok, %{port: port, pid: pid, identity: identity}}
  rescue
    error -> {:error, {:process_launch_failed, Exception.message(error)}}
  end

  defp leader(controller, owner_monitor, deadline, buffer) do
    receive do
      {^controller, {:data, chunk}} ->
        buffer = buffer <> chunk

        case String.split(buffer, "\n", parts: 2) do
          ["omj:" <> pid, _rest] ->
            with {pid, ""} <- Integer.parse(pid),
                 {:ok, identity} <- process_identity(pid),
                 true <-
                   identity.group == Integer.to_string(pid) and
                     identity.session == Integer.to_string(pid) do
              {:ok, pid, identity}
            else
              _invalid -> {:error, :process_leader_unavailable}
            end

          _partial when byte_size(buffer) <= 128 ->
            leader(controller, owner_monitor, deadline, buffer)

          _invalid ->
            {:error, :invalid_process_handshake}
        end

      {^controller, {:exit_status, code}} ->
        {:error, {:process_launcher_exit, code}}

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        {:error, :process_owner_down}
    after
      remaining(deadline) -> {:error, :process_start_timeout}
    end
  end

  defp collect(state) do
    state = advance(state)

    if finished?(state) do
      %{result: result(state), waiters: state.waiters}
    else
      receive do
        {port, {:data, data}} when is_map_key(state.ports, port) ->
          collect(retain(state, state.ports[port], data))

        {port, :eof} when is_map_key(state.ports, port) ->
          collect(%{state | eof: Map.put(state.eof, state.ports[port], true)})

        {port, {:exit_status, code}} when is_map_key(state.ports, port) ->
          if port == state.controller do
            collect(%{state | exit_status: code})
          else
            collect(%{
              state
              | eof: Map.put(state.eof, state.ports[port], true),
                cleanup_error: state.cleanup_error or code != 0
            })
          end

        {:EXIT, port, :normal} when is_map_key(state.ports, port) ->
          collect(%{state | eof: Map.put(state.eof, state.ports[port], true)})

        {:EXIT, port, _reason} when is_map_key(state.ports, port) ->
          state = %{state | cleanup_error: true, eof: Map.put(state.eof, state.ports[port], true)}
          collect(if(port == state.controller, do: stop(state, :failed), else: state))

        {:cancel, ref, requester, reply} when ref == state.ref ->
          state = %{state | waiters: [{requester, reply} | state.waiters]}
          collect(stop(state, :cancelled))

        {:DOWN, monitor, :process, owner, _reason}
        when monitor == state.owner_monitor and owner == state.owner ->
          collect(stop(state, :owner_down))

        {:DOWN, monitor, :process, _lease, _reason} when monitor == state.lease_monitor ->
          collect(stop(state, :owner_down))

        {:DOWN, monitor, :process, _coordinator, _reason}
        when monitor == state.coordinator_monitor ->
          collect(stop(state, :owner_down))
      after
        @poll_ms -> collect(state)
      end
    end
  end

  defp advance(%{status: :running} = state) do
    cond do
      not is_nil(state.exit_status) -> stop(state, :exited)
      now() >= state.deadline -> stop(state, :timed_out)
      true -> state
    end
  end

  defp advance(state) do
    if not state.kill_sent and now() >= state.stopping_at + state.request.grace do
      outcome = signal_group(state.request.helpers["kill"], state.pid, state.identity, "KILL")
      %{state | kill_sent: true, cleanup_error: state.cleanup_error or outcome == :uncertain}
    else
      state
    end
  end

  defp stop(%{status: :running} = state, status) do
    background = status == :exited and not group_empty?(state.pid, state.identity)
    outcome = signal_group(state.request.helpers["kill"], state.pid, state.identity, "TERM")

    %{
      state
      | status: status,
        stopping_at: now(),
        cleanup_error: state.cleanup_error or outcome == :uncertain,
        background_cleanup: background
    }
  end

  defp stop(state, _status), do: state

  defp finished?(%{status: :running}), do: false

  defp finished?(state) do
    drained = Map.get(state.eof, :stdout, false) and Map.get(state.eof, :stderr, false)
    expired = now() >= state.stopping_at + state.request.grace + @cleanup_timeout

    expired or
      (drained and not is_nil(state.exit_status) and group_empty?(state.pid, state.identity))
  end

  defp retain(state, :control, _data), do: state

  defp retain(state, stream, data) do
    count = min(byte_size(data), max(state.request.cap - state.retained[stream], 0))
    kept = binary_part(data, 0, count)
    if count > 0, do: publish_output(state, stream, kept)
    chunks = if count > 0, do: Map.update!(state.chunks, stream, &[kept | &1]), else: state.chunks

    %{
      state
      | chunks: chunks,
        retained: Map.update!(state.retained, stream, &(&1 + count)),
        output_bytes: Map.update!(state.output_bytes, stream, &(&1 + byte_size(data)))
    }
  end

  defp publish_output(state, stream, data) do
    recipient = if is_pid(state.request.on_output), do: state.request.on_output, else: state.owner

    if state.request.on_output,
      do: send(recipient, {:oh_my_jido_process_output, state.ref, stream, data})

    context = state.request.context

    if context.coordinator do
      send(
        context.coordinator,
        {:process_output, context.session_id, context.run_id, state.ref, stream, data}
      )
    end
  end

  defp result(state) do
    cleanup =
      if not state.cleanup_error and group_empty?(state.pid, state.identity),
        do: :confirmed,
        else: :uncertain

    cancellation =
      if state.status in [:cancelled, :timed_out, :owner_down], do: cleanup, else: :not_requested

    %{
      stdout: state.chunks.stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: state.chunks.stderr |> Enum.reverse() |> IO.iodata_to_binary(),
      status: state.status,
      exit_status: state.exit_status,
      os_pid: state.pid,
      duration_ms: now() - state.start,
      output_bytes: state.output_bytes,
      truncated:
        state.output_bytes.stdout > state.retained.stdout or
          state.output_bytes.stderr > state.retained.stderr,
      cleanup: cleanup,
      cancellation: cancellation,
      effect: effect_status(state, cleanup)
    }
  end

  defp effect_status(%{execution_started: false}, _cleanup), do: :not_started

  defp effect_status(%{status: :exited, background_cleanup: false}, :confirmed),
    do: :completed

  defp effect_status(_state, _cleanup), do: :uncertain

  defp process_identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_stat, fields] <- Regex.run(~r/^\d+ \(.*\) (.*)$/s, stat),
         [
           state,
           parent,
           group,
           session,
           _tty,
           _tpgid,
           _flags,
           _minflt,
           _cminflt,
           _majflt,
           _cmajflt,
           _utime,
           _stime,
           _cutime,
           _cstime,
           _priority,
           _nice,
           _threads,
           _interval,
           start | _rest
         ] <- String.split(fields) do
      {:ok,
       %{
         state: state,
         parent: parent,
         group: group,
         session: session,
         start: start
       }}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_process_stat}
    end
  end

  defp group_members(pid, identity) do
    with :ok <- matching_identity(pid, identity),
         {:ok, entries} <- File.ls("/proc") do
      Enum.reduce_while(entries, {:ok, []}, &group_member(&1, identity, &2))
    end
  end

  defp group_member(name, identity, {:ok, members}) do
    case Integer.parse(name) do
      {member, ""} -> collect_member(member, identity, members)
      _other -> {:cont, {:ok, members}}
    end
  end

  defp collect_member(member, identity, members) do
    case process_identity(member) do
      {:ok, %{group: group, session: session, state: status}}
      when group == identity.group and session == identity.session and status not in ["Z", "X"] ->
        {:cont, {:ok, [member | members]}}

      {:ok, _other} ->
        {:cont, {:ok, members}}

      {:error, reason} when reason in [:enoent, :esrch] ->
        {:cont, {:ok, members}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp matching_identity(pid, identity) do
    case process_identity(pid) do
      {:ok, %{start: start}} when start != identity.start -> {:error, :process_identity_changed}
      {:ok, _same} -> :ok
      {:error, reason} when reason in [:enoent, :esrch] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp group_empty?(pid, identity), do: group_members(pid, identity) == {:ok, []}

  defp signal_group(kill, pid, identity, signal) do
    case group_members(pid, identity) do
      {:ok, []} ->
        :ok

      {:ok, _members} ->
        send_group_signal(kill, pid, identity, signal)

      {:error, _reason} ->
        :uncertain
    end
  rescue
    _error -> :uncertain
  end

  defp send_group_signal(kill, pid, identity, signal) do
    case System.cmd(kill, ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _failed -> if group_empty?(pid, identity), do: :ok, else: :uncertain
    end
  end

  defp close_port(child, kill) do
    if child.identity do
      case process_identity(child.pid) do
        {:ok, %{start: start}} when start == child.identity.start ->
          System.cmd(kill, ["-KILL", "--", Integer.to_string(child.pid)], stderr_to_stdout: true)

        _exited_or_reused ->
          :ok
      end
    end

    if Port.info(child.port), do: Port.close(child.port)
  rescue
    _error -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now(), 0)
end
