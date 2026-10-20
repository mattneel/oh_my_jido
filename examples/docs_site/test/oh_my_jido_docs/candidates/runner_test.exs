defmodule OhMyJidoDocs.Candidates.RunnerTest do
  use ExUnit.Case, async: false

  alias OhMyJidoDocs.Candidates.{Candidate, EffectLease, Runner}

  @moduletag timeout: 60_000

  setup do
    root = Path.join(System.tmp_dir!(), "docs-runner-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "home"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule DocsRunnerFixture.MixProject do
      use Mix.Project
      def project, do: [app: :docs_runner_fixture, version: "0.1.0", deps: []]
      # Keep the resource probe's OTP dependency on Mix's pruned code path.
      def application, do: [extra_applications: [:crypto]]
    end
    """)

    File.write!(Path.join(root, "lib/fixture.ex"), """
    defmodule DocsRunnerFixture do
      def total(values), do: Enum.reduce(values, 0, &+/2)
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/fixture_test.exs"), """
    defmodule DocsRunnerFixtureTest do
      use ExUnit.Case
      test "calculates from real compiled source" do
        assert DocsRunnerFixture.total([10, 11, 21]) ==
                 String.to_integer(System.get_env("FIXTURE_EXPECTED", "42"))
      end
    end
    """)

    File.write!(Path.join(root, "probe.exs"), probe_source())
    {:ok, mix} = Runner.available("mix")
    {:ok, elixir} = Runner.available("elixir")
    {:ok, erl} = Runner.available("erl")

    path =
      [Path.dirname(mix), Path.dirname(elixir), Path.dirname(erl), "/usr/bin", "/bin"]
      |> Enum.uniq()
      |> Enum.join(":")

    env = %{
      "PATH" => path,
      "LANG" => "C.UTF-8",
      "HOME" => Path.join(root, "home"),
      "MIX_HOME" => Path.join(root, "home/mix"),
      "HEX_HOME" => Path.join(root, "home/hex"),
      "MIX_ENV" => "test",
      "ERL_FLAGS" => "+S 2:2 +A 1"
    }

    supervisor = start_supervised!({Task.Supervisor, []})
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, mix: mix, env: env, supervisor: supervisor}
  end

  test "runs actual Mix compilation/tests and preserves nonzero exit results", context do
    passed = Runner.run(context.mix, ["test", "--no-color"], options(context))
    assert passed["status"] == "passed", receipt_failure(passed)
    assert passed["exit_status"] == 0
    assert passed["launcher_exit_status"] == 0
    assert passed["command_started"]
    assert passed["dispatch"] == "acknowledged"
    assert passed["cleanup"]["status"] == "confirmed"
    assert passed["cleanup"]["port_reaped"]
    assert passed["cleanup"]["all_children_reaped"]
    assert passed["cleanup"]["authority"] == "linux_child_subreaper_waitpid"
    assert passed["process_keeper"]["launch_id"] == passed["launch_id"]

    {:ok, python} =
      Runner.available(
        Application.get_env(:oh_my_jido_docs, :candidate_python_executable, "python3")
      )

    assert passed["process_keeper"]["executable"] == python
    assert passed["output_complete"]
    assert passed["cwd"] == context.root
    assert Path.type(passed["executable"]) == :absolute
    assert passed["process_identity"]["start_time"] =~ ~r/^\d+$/
    assert passed["process_identity"]["pid"] == passed["os_pid"]
    assert {:ok, _started, 0} = DateTime.from_iso8601(passed["started_at"])
    assert {:ok, _finished, 0} = DateTime.from_iso8601(passed["finished_at"])
    assert is_integer(passed["duration_ms"])
    assert Jason.decode!(Jason.encode!(passed)) == passed

    failed =
      Runner.run(
        context.mix,
        ["test", "--no-color"],
        options(context, env: Map.put(context.env, "FIXTURE_EXPECTED", "0"))
      )

    assert failed["status"] == "failed"
    assert failed["exit_status"] != 0
    assert failed["cleanup"]["status"] == "confirmed"
  end

  test "retains complete cleanup for long serial operating-system workloads", context do
    previous_data = Application.fetch_env(:oh_my_jido_docs, :data_dir)
    Application.put_env(:oh_my_jido_docs, :data_dir, Path.join(context.root, "lease-data"))

    on_exit(fn ->
      case previous_data do
        {:ok, value} -> Application.put_env(:oh_my_jido_docs, :data_dir, value)
        :error -> Application.delete_env(:oh_my_jido_docs, :data_dir)
      end
    end)

    candidate = %Candidate{
      id: Ecto.UUID.generate(),
      check_receipt: %{"attempt_id" => Ecto.UUID.generate()}
    }

    assert {:ok, lease} = EffectLease.acquire(candidate, :check)

    source = ~S"""
    sleep = System.find_executable("sleep") || raise "sleep unavailable"

    completed =
      Enum.reduce(1..160, 0, fn _index, count ->
        {"", 0} = System.cmd(sleep, ["0.08"])
        count + 1
      end)

    IO.puts(completed)
    """

    receipt =
      Runner.run(
        context.mix,
        ["run", "--no-compile", "--no-start", "-e", source],
        options(context,
          before_start: &EffectLease.begin_launch(lease, &1),
          on_start: &EffectLease.record_process(lease, &1),
          on_scope: &EffectLease.record_process(lease, &1)
        )
      )

    assert receipt["status"] == "passed", receipt_failure(receipt)
    assert receipt["exit_status"] == 0
    assert receipt["output"] |> String.trim() |> String.to_integer() == 160
    assert receipt["owned_processes_complete"]
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["all_children_reaped"]
    assert receipt["cleanup"]["keeper_terminated"]

    active = EffectLease.path() |> File.read!() |> Jason.decode!()
    assert active["process"]["owned_processes_complete"]
    assert active["process"]["scope_error"] == nil
    assert :ok = EffectLease.complete(lease, receipt)
    assert :ok = EffectLease.available()
    released_path = Path.join(Path.dirname(EffectLease.path()), "process-lease-receipt.json")
    released = released_path |> File.read!() |> Jason.decode!()
    assert released["process"]["owned_processes_complete"]
    assert released["cleanup"]["status"] == "confirmed"
  end

  test "consumes queued matching cancellation before spawning a real command", context do
    marker = Path.join(context.root, "must-not-launch")
    cancel_ref = make_ref()
    send(self(), {:cancel, cancel_ref})

    receipt =
      Runner.run(
        context.mix,
        ["run", "--no-start", "-e", "File.write!(System.fetch_env!(\"MARKER\"), \"launched\")"],
        options(context, cancel_ref: cancel_ref, env: Map.put(context.env, "MARKER", marker))
      )

    assert receipt["status"] == "cancelled"
    assert receipt["cancellation"] == "not_started"
    assert receipt["effect"] == "not_started"
    assert receipt["cleanup"]["status"] == "not_started"
    assert is_nil(receipt["os_pid"])
    assert is_nil(receipt["launcher_pid"])
    refute File.exists?(marker)
    refute File.exists?(Path.join(context.root, "_build"))
  end

  test "synchronous launch authorization runs before any real subprocess opens", context do
    marker = Path.join(context.root, "launch-denied")
    parent = self()

    receipt =
      Runner.run(
        context.mix,
        ["run", "--no-start", "-e", "File.write!(System.fetch_env!(\"MARKER\"), \"launched\")"],
        options(context,
          env: Map.put(context.env, "MARKER", marker),
          before_start: fn launch ->
            assert {:ok, _} = Ecto.UUID.cast(launch["launch_id"])
            assert is_nil(launch["os_pid"])
            assert is_nil(launch["launcher_pid"])
            refute File.exists?(marker)
            send(parent, {:observed_prelaunch, launch["launch_id"]})
            {:error, :not_authorized}
          end
        )
      )

    assert_receive {:observed_prelaunch, generation}
    assert receipt["launch_id"] == generation
    assert receipt["status"] == "unavailable"
    assert receipt["error"] == "launch_not_authorized"
    assert receipt["effect"] == "not_started"
    assert receipt["cleanup"]["status"] == "not_started"
    refute File.exists?(marker)
    refute File.exists?(Path.join(context.root, "_build"))
  end

  test "synchronous authorization consumes the independent keeper deadline budget", context do
    {:ok, sleep} = Runner.available("sleep")

    receipt =
      Runner.run(
        sleep,
        ["0"],
        options(context,
          timeout_ms: 2_000,
          before_start: fn _launch ->
            Process.sleep(500)
            :ok
          end
        )
      )

    assert receipt["status"] == "passed", receipt_failure(receipt)
    assert receipt["os_timeout_ms"] >= 1_000
    assert receipt["os_timeout_ms"] <= 2_500
    assert receipt["cleanup"]["status"] == "confirmed"
  end

  test "does not dispatch real Mix until its on_start acknowledgement completes", context do
    parent = self()
    marker = Path.join(context.root, "dispatch.marker")

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Runner.run(
          context.mix,
          [
            "run",
            "--no-compile",
            "--no-start",
            "-e",
            "File.write!(\"dispatch.marker\", \"started\")"
          ],
          options(context,
            on_start: fn receipt ->
              send(parent, {:dispatch_waiting, self(), receipt})

              receive do
                :continue_dispatch -> :ok
              end
            end
          )
        )
      end)

    assert_receive {:dispatch_waiting, callback, started}, 5_000
    status_path = started["process_keeper"]["status_path"]
    eventually(fn -> File.regular?(status_path) end)
    ready = status_path |> File.read!() |> Jason.decode!()
    refute ready["main_started"]
    assert ready["keeper_identity"]["pid"] == started["os_pid"]
    refute File.exists?(status_path <> ".ack")
    refute File.exists?(marker)
    refute File.exists?(Path.join(context.root, "_build"))

    send(callback, :continue_dispatch)
    receipt = Task.await(task, 10_000)
    assert receipt["status"] == "passed", receipt_failure(receipt)
    assert receipt["command_started"]
    assert receipt["dispatch"] == "acknowledged"
    assert receipt["cleanup"]["all_children_reaped"]
    assert File.read!(marker) == "started"
    acknowledgement = (status_path <> ".ack") |> File.read!() |> Jason.decode!()
    assert acknowledgement["launch_id"] == started["launch_id"]

    assert acknowledgement["keeper_identity"]["start_time"] ==
             started["process_identity"]["start_time"]
  end

  test "the accepting keeper rejects an ACK whose directory cannot be durably synced", context do
    {:ok, python} =
      Runner.available(
        Application.get_env(:oh_my_jido_docs, :candidate_python_executable, "python3")
      )

    directory = Path.join(context.root, "ack-consumer")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    marker = Path.join(directory, "must-not-start")
    script = Path.join(:code.priv_dir(:oh_my_jido_docs), "candidate_process_keeper.py")

    source = ~S"""
    import errno, json, os, runpy, sys, types, uuid
    module = runpy.run_path(sys.argv[1], run_name="trusted_keeper_ack_fault")
    arguments = types.SimpleNamespace(
        status=os.path.join(sys.argv[2], "status.json"),
        launch_id=str(uuid.uuid4()), timeout_ms=2000,
        command=[sys.executable, "-I", "-B", "-S", "-c",
                 "import pathlib,sys;pathlib.Path(sys.argv[1]).write_text('started')",
                 sys.argv[3]],
    )
    keeper = module["Keeper"](arguments)
    with open(arguments.status + ".ack", "xb") as acknowledgement:
        os.fchmod(acknowledgement.fileno(), 0o600)
        acknowledgement.write(json.dumps({
            "schema": 1, "launch_id": arguments.launch_id,
            "keeper_identity": keeper.keeper_identity,
        }).encode())
        acknowledgement.flush()
        os.fsync(acknowledgement.fileno())
    original_sync = os.fsync
    failed = False
    def fail_accepting_directory_once(descriptor):
        global failed
        if descriptor == keeper.directory and not failed:
            failed = True
            raise OSError(errno.EIO, "injected accepting-directory sync failure")
        return original_sync(descriptor)
    os.fsync = fail_accepting_directory_once
    assert keeper.run() == 125
    with open(arguments.status) as status_file:
        status = json.load(status_file)
    assert failed
    assert status["cleanup"]["status"] == "not_started"
    assert not status["main_started"]
    assert not os.path.exists(sys.argv[3])
    """

    receipt =
      Runner.run(
        python,
        ["-I", "-B", "-S", "-c", source, script, directory, marker],
        options(context)
      )

    assert receipt["status"] == "passed", receipt_failure(receipt)
    refute File.exists?(marker)
    status = directory |> Path.join("status.json") |> File.read!() |> Jason.decode!()
    assert status["cleanup"]["status"] == "not_started"
    refute status["main_started"]
  end

  test "incomplete child and identity scans retain the last complete live inventory", context do
    {:ok, python} =
      Runner.available(
        Application.get_env(:oh_my_jido_docs, :candidate_python_executable, "python3")
      )

    script = Path.join(:code.priv_dir(:oh_my_jido_docs), "candidate_process_keeper.py")

    source = ~S"""
    import builtins, errno, json, os, runpy, subprocess, sys, types, uuid
    module = runpy.run_path(sys.argv[1], run_name="trusted_keeper_live_fault")
    for mode in ["children", "identity"]:
        directory = os.path.join(sys.argv[2], "live-" + mode)
        os.mkdir(directory, 0o700)
        arguments = types.SimpleNamespace(
            status=os.path.join(directory, "status.json"),
            launch_id=str(uuid.uuid4()), timeout_ms=2000, command=[],
        )
        keeper = module["Keeper"](arguments)
        child = subprocess.Popen(
            [sys.executable, "-I", "-B", "-S", "-c", "import time; time.sleep(10)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            keeper.observe_descendants(keeper.children())
            keeper.persist("running", None, False, keeper.children())
            with open(arguments.status) as saved:
                before = json.load(saved)
            assert any(item["pid"] == child.pid for item in before["live_processes"])
            original_open = builtins.open
            target = (
                f"/proc/self/task/{os.getpid()}/children" if mode == "children"
                else f"/proc/{child.pid}/stat"
            )
            def fail_observation(path, *args, **kwargs):
                if path == target:
                    raise OSError(errno.EIO, "injected live observation failure")
                return original_open(path, *args, **kwargs)
            builtins.open = fail_observation
            try:
                keeper.observe_descendants(keeper.children())
            finally:
                builtins.open = original_open
            keeper.persist("settling", keeper.scope_error, False, [])
            with open(arguments.status) as saved:
                after = json.load(saved)
            assert not after["owned_processes_complete"]
            assert after["live_processes"] == before["live_processes"]
            assert after["cleanup"]["status"] == "uncertain"
            assert not after["cleanup"]["all_children_reaped"]
            assert child.poll() is None
        finally:
            child.kill()
            child.wait()
            os.close(keeper.directory)
    """

    receipt =
      Runner.run(
        python,
        ["-I", "-B", "-S", "-c", source, script, context.root],
        options(context)
      )

    assert receipt["status"] == "passed", receipt_failure(receipt)
    assert receipt["cleanup"]["all_children_reaped"]
  end

  test "a failed keeper-identity callback never dispatches the actual Mix target", context do
    marker = Path.join(context.root, "dispatch.marker")

    receipt =
      Runner.run(
        context.mix,
        [
          "run",
          "--no-compile",
          "--no-start",
          "-e",
          "File.write!(\"dispatch.marker\", \"started\")"
        ],
        options(context, on_start: fn _receipt -> {:error, :lease_persistence_failed} end)
      )

    assert receipt["status"] == "failed", receipt_failure(receipt)
    assert receipt["error"] == "on_start_failed"
    assert receipt["on_start"] == "failed"
    refute receipt["command_started"]
    assert receipt["effect"] == "not_started"
    assert receipt["cleanup"]["status"] == "not_started"
    assert receipt["cleanup"]["keeper_terminated"]
    assert receipt["cleanup"]["port_reaped"]
    refute File.exists?(marker)
    refute File.exists?(receipt["process_keeper"]["status_path"] <> ".ack")
    refute alive?(receipt["os_pid"])
  end

  test "cancellation interrupts a gated startup callback without dispatch or a ten-second await",
       context do
    parent = self()
    cancel_ref = make_ref()
    marker = Path.join(context.root, "dispatch.marker")

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Runner.run(
          context.mix,
          [
            "run",
            "--no-compile",
            "--no-start",
            "-e",
            "File.write!(\"dispatch.marker\", \"started\")"
          ],
          options(context,
            cancel_ref: cancel_ref,
            on_start: fn receipt ->
              send(parent, {:dispatch_gated, receipt})
              Process.sleep(:infinity)
            end
          )
        )
      end)

    assert_receive {:dispatch_gated, started}, 5_000
    send(task.pid, {:cancel, cancel_ref})
    receipt = Task.await(task, 10_000)
    assert receipt["status"] == "cancelled", receipt_failure(receipt)
    assert receipt["on_start"] == "cancelled"
    assert receipt["cancellation"] == "not_started"
    assert receipt["cleanup"]["status"] == "not_started"
    assert receipt["cleanup"]["keeper_terminated"]
    refute receipt["command_started"]
    refute File.exists?(marker)
    refute File.exists?(started["process_keeper"]["status_path"] <> ".ack")
    refute alive?(started["os_pid"])
  end

  test "samples real Mix memory and CPU workload with explicit resource uncertainty", context do
    receipt = Runner.run(context.mix, probe_args("resources"), options(context))
    resources = receipt["resources"]

    assert receipt["status"] == "passed", receipt_failure(receipt)
    assert resources["status"] == "sampled"
    assert resources["sample_count"] >= 2
    assert resources["observed_peak_rss_bytes"] > 0
    assert resources["observed_peak_group_process_count"] >= 2
    assert resources["observed_cpu_ticks"] > 0
    assert resources["clock_ticks_per_second"] > 0
    assert resources["page_size_bytes"] > 0
    refute resources["peak_is_exact"]
    assert Jason.decode!(Jason.encode!(receipt)) == receipt
    assert receipt["command_started"]
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["all_children_reaped"]
    assert receipt["cleanup"]["port_reaped"]
    refute alive?(receipt["os_pid"])
  end

  test "passes only explicit environment, supplies stdin EOF and redacts chunk-spanning secrets",
       context do
    key = "DOCS_RUNNER_AMBIENT_TEST_SECRET"
    original = System.get_env(key)
    System.put_env(key, "synthetic-parent-only-value")

    on_exit(fn ->
      if original, do: System.put_env(key, original), else: System.delete_env(key)
    end)

    secret = "synthetic-private-token-8c9e927a"
    env = Map.merge(context.env, %{key => nil, "RUNNER_EXPLICIT_SECRET" => secret})

    receipt =
      Runner.run(
        context.mix,
        probe_args("inspect"),
        options(context, env: env, redactions: [secret])
      )

    assert receipt["status"] == "passed"
    assert receipt["output"] =~ "ambient=absent"
    assert receipt["output"] =~ "stdin=:eof"
    assert receipt["output"] =~ "[REDACTED]"
    refute receipt["output"] =~ secret
    refute Jason.encode!(receipt) =~ "synthetic-parent-only-value"
    refute Jason.encode!(receipt) =~ secret
    refute Map.has_key?(receipt, "env")
    assert String.valid?(receipt["output"])
    assert System.get_env(key) == "synthetic-parent-only-value"
  end

  test "uses the absolute child cwd without changing the host cwd", context do
    host_cwd = File.cwd!()
    receipt = Runner.run(context.mix, probe_args("cwd"), options(context))
    assert receipt["status"] == "passed"
    assert receipt["output"] =~ context.root
    assert File.cwd!() == host_cwd
  end

  test "bounds output storage, counts discarded bytes and cleans the real Mix group", context do
    receipt =
      Runner.run(context.mix, probe_args("flood"), options(context, max_output_bytes: 1_024))

    assert receipt["status"] == "output_limit"
    assert receipt["output_bytes"] > 1_024
    assert byte_size(receipt["output"]) <= 1_024
    assert receipt["truncated"]
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["port_reaped"]
    assert Jason.encode!(receipt)
    refute alive?(receipt["os_pid"])
  end

  test "does not expose a secret prefix cut by the output limit", context do
    secret = "private-X-token-secret-with-a-longer-tail"

    receipt =
      Runner.run(
        context.mix,
        probe_args("prefix"),
        options(context,
          env: Map.put(context.env, "RUNNER_EXPLICIT_SECRET", secret),
          redactions: [secret, "X"],
          max_output_bytes: 16
        )
      )

    assert receipt["status"] == "output_limit"
    assert byte_size(receipt["output"]) <= 16
    assert receipt["output"] =~ "[REDACTED]"
    refute receipt["output"] =~ "private"
  end

  test "enforces a deadline on a real blocked Mix child", context do
    receipt =
      Runner.run(context.mix, probe_args("hold"), options(context, timeout_ms: 2_000))

    assert receipt["status"] == "timed_out"
    assert receipt["deadline_exceeded"]
    assert receipt["duration_ms"] < 10_000
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["port_reaped"]
    refute alive?(receipt["os_pid"])
  end

  test "an independent keeper deadline cannot turn a graceful zero exit into success", context do
    {:ok, python} =
      Runner.available(
        Application.get_env(:oh_my_jido_docs, :candidate_python_executable, "python3")
      )

    wrapper = Path.join(context.root, "short-keeper-deadline")
    marker = Path.join(context.root, "independent-deadline-ready")

    # This trusted test wrapper changes only the real keeper's deadline and
    # execs the configured interpreter: ownership, ACK and receipts stay real.
    File.write!(wrapper, """
    #!#{python}
    import os, sys
    arguments = sys.argv[1:]
    arguments[arguments.index("--timeout-ms") + 1] = "1200"
    os.execv(#{inspect(python)}, [#{inspect(python)}, *arguments])
    """)

    File.chmod!(wrapper, 0o700)

    source = ~S"""
    import pathlib, signal, sys, time
    signal.signal(signal.SIGTERM, lambda *_arguments: sys.exit(0))
    pathlib.Path(sys.argv[1]).write_text("ready")
    time.sleep(60)
    """

    receipt =
      Runner.run(
        python,
        ["-I", "-B", "-S", "-c", source, marker],
        options(context, candidate_python_executable: wrapper)
      )

    assert File.read!(marker) == "ready"
    assert receipt["exit_status"] == 0, receipt_failure(receipt)
    assert receipt["status"] == "timed_out"
    assert receipt["deadline_exceeded"]
    assert receipt["cleanup"]["keeper_timed_out"]
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["all_children_reaped"]
    refute receipt["effect"] == "completed"
  end

  test "cancels real Mix execution and its owned OS descendant", context do
    {task, cancel_ref, started} = launch(context, "descendant")
    descendant = descendant_pid!(context)
    started = descendant_scope!(started, descendant)
    assert alive?(started["os_pid"])
    assert alive?(descendant)

    send(task.pid, {:cancel, cancel_ref})
    receipt = Task.await(task, 10_000)

    assert receipt["status"] == "cancelled"
    assert receipt["cancellation"] == "confirmed"
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["term"] == "sent"
    assert receipt["launch_id"] == started["launch_id"]
    assert receipt["owned_processes_complete"]
    assert Enum.any?(receipt["owned_processes"], &(&1["pid"] == descendant))
    refute alive?(started["os_pid"])
    refute alive?(descendant)
  end

  test "observes a separate-session child forked by a non-leader OS thread", context do
    {:ok, python} =
      Runner.available(
        Application.get_env(:oh_my_jido_docs, :candidate_python_executable, "python3")
      )

    {:ok, sleep} = Runner.available("sleep")
    marker = Path.join(context.root, "thread-descendant.json")
    parent = self()
    cancel_ref = make_ref()

    source = ~S"""
    import json, os, pathlib, sys, threading, time
    def fork_from_thread():
        reader, writer = os.pipe()
        child = os.fork()
        if child == 0:
            os.close(reader)
            os.setsid()
            os.write(writer, b"1")
            os.close(writer)
            os.execv(sys.argv[2], [sys.argv[2], "60"])
        os.close(writer)
        assert os.read(reader, 1) == b"1"
        os.close(reader)
        pathlib.Path(sys.argv[1]).write_text(json.dumps({
            "pid": os.getpid(), "thread": threading.get_native_id(), "child": child,
        }))
        threading.Event().wait(60)
    threading.Thread(target=fork_from_thread).start()
    time.sleep(60)
    """

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Runner.run(
          python,
          ["-I", "-B", "-S", "-c", source, marker, sleep],
          options(context,
            cancel_ref: cancel_ref,
            on_start: fn receipt ->
              send(parent, {:thread_descendant_started, receipt})
              :ok
            end,
            on_scope: fn receipt ->
              send(parent, {:scope, receipt["launch_id"], receipt})
              :ok
            end
          )
        )
      end)

    assert_receive {:thread_descendant_started, started}, 5_000
    eventually(fn -> File.regular?(marker) and File.read!(marker) != "" end)
    actual = marker |> File.read!() |> Jason.decode!()
    refute actual["thread"] == actual["pid"]

    children =
      "/proc/#{actual["pid"]}/task/#{actual["thread"]}/children"
      |> File.read!()
      |> String.split()

    assert Integer.to_string(actual["child"]) in children

    leader_children =
      "/proc/#{actual["pid"]}/task/#{actual["pid"]}/children"
      |> File.read!()
      |> String.split()

    refute Integer.to_string(actual["child"]) in leader_children
    observed = descendant_scope!(started, actual["child"])
    assert observed["owned_processes_complete"]
    send(task.pid, {:cancel, cancel_ref})
    receipt = Task.await(task, 10_000)
    assert receipt["status"] == "cancelled", receipt_failure(receipt)
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["all_children_reaped"]
    descendant = Enum.find(receipt["owned_processes"], &(&1["pid"] == actual["child"]))
    assert descendant["process_group"] == actual["child"]
    assert descendant["session"] == actual["child"]
    refute alive?(actual["child"])
  end

  test "settles a real Port descendant even when its Mix parent exits between observations",
       context do
    receipt = Runner.run(context.mix, probe_args("orphan"), options(context))
    descendant = descendant_pid!(context)

    assert receipt["status"] == "passed", receipt_failure(receipt)
    assert receipt["exit_status"] == 0
    assert receipt["duration_ms"] < 10_000
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["port_reaped"]
    assert receipt["cleanup"]["all_children_reaped"]
    assert receipt["cleanup"]["authority"] == "linux_child_subreaper_waitpid"
    refute alive?(descendant)
  end

  test "escalates to KILL for a real Mix-owned OS descendant proven to ignore TERM", context do
    {task, cancel_ref, started} = launch(context, "stubborn")
    descendant = descendant_pid!(context)
    started = descendant_scope!(started, descendant)
    eventually(fn -> term_ignored?(descendant) end)
    assert alive?(descendant)
    send(task.pid, {:cancel, cancel_ref})
    receipt = Task.await(task, 10_000)

    assert receipt["status"] == "cancelled"
    assert receipt["cleanup"]["term"] == "sent"
    assert receipt["cleanup"]["kill"] == "sent"
    assert receipt["cleanup"]["status"] == "confirmed"
    refute alive?(started["os_pid"])
    refute alive?(descendant)
    assert Enum.any?(receipt["owned_processes"], &(&1["pid"] == descendant))
  end

  test "proves an owned exact loopback listener and rejects unrelated or stale ownership",
       context do
    {task, cancel_ref, started} = launch(context, "listener")
    path = Path.join(context.root, "listener.port")
    eventually(fn -> File.regular?(path) and File.read!(path) != "" end)
    port = path |> File.read!() |> String.to_integer()
    persisted = started |> Jason.encode!() |> Jason.decode!()
    eventually(fn -> Runner.listener_owned?(persisted, port) end)

    {:ok, unrelated} = :gen_tcp.listen(0, active: false, ip: {127, 0, 0, 1})
    {:ok, {{127, 0, 0, 1}, unrelated_port}} = :inet.sockname(unrelated)
    refute Runner.listener_owned?(persisted, unrelated_port)
    :ok = :gen_tcp.close(unrelated)

    stale =
      put_in(
        persisted,
        ["process_identity", "start_time"],
        Integer.to_string(String.to_integer(persisted["process_identity"]["start_time"]) + 1)
      )

    refute Runner.listener_owned?(stale, port)

    refute Runner.listener_owned?(
             put_in(persisted, ["process_identity", "boot_id"], "other-boot"),
             port
           )

    refute Runner.listener_owned?(persisted, 0)
    assert alive?(started["os_pid"])

    send(task.pid, {:cancel, cancel_ref})
    receipt = Task.await(task, 10_000)
    assert receipt["status"] == "cancelled"
    refute Runner.listener_owned?(receipt, port)
  end

  test "proves the exact listener in an owned external Elixir Port descendant", context do
    {task, cancel_ref, started} = launch(context, "descendant_listener")
    descendant = descendant_pid!(context)
    observed = descendant_scope!(started, descendant)
    path = Path.join(context.root, "listener.port")
    eventually(fn -> File.regular?(path) and File.read!(path) != "" end)
    port = path |> File.read!() |> String.to_integer()
    persisted = observed |> Jason.encode!() |> Jason.decode!()

    eventually(fn -> Runner.listener_owned?(persisted, port) end)
    assert alive?(descendant)
    send(task.pid, {:cancel, cancel_ref})
    receipt = Task.await(task, 10_000)
    assert receipt["cancellation"] == "confirmed"
    refute alive?(descendant)
    refute Runner.listener_owned?(receipt, port)
  end

  test "rejects an owned wildcard TCP listener rather than treating it as loopback", context do
    {task, cancel_ref, started} = launch(context, "wildcard_listener")
    path = Path.join(context.root, "listener.port")
    eventually(fn -> File.regular?(path) and File.read!(path) != "" end)
    port = path |> File.read!() |> String.to_integer()
    refute Runner.listener_owned?(started, port)

    send(task.pid, {:cancel, cancel_ref})
    assert Task.await(task, 10_000)["status"] == "cancelled"
  end

  test "refuses a reused identity and supports persisted receipt cleanup", context do
    {task, _cancel_ref, started} = launch(context, "descendant")
    descendant = descendant_pid!(context)
    started = descendant_scope!(started, descendant)

    stale =
      put_in(
        started,
        ["process_identity", "start_time"],
        Integer.to_string(String.to_integer(started["process_identity"]["start_time"]) + 1)
      )

    refused = Runner.stop(stale)
    assert refused["status"] == "uncertain"
    assert refused["reason"] == "process_identity_changed"
    assert refused["term"] == "not_sent"
    assert alive?(started["os_pid"])
    assert alive?(descendant)

    persisted = started |> Jason.encode!() |> Jason.decode!()
    cleanup = Runner.stop(persisted)
    assert cleanup["status"] == "confirmed", inspect(cleanup)
    assert cleanup["scope_observed"]
    assert cleanup["owned_processes_complete"]
    assert Enum.any?(cleanup["owned_processes"], &(&1["pid"] == descendant))
    receipt = Task.await(task, 10_000)
    assert receipt["status"] == "failed"
    assert receipt["cleanup"]["status"] == "confirmed"
    refute alive?(descendant)
    assert Runner.stop(persisted)["status"] == "confirmed"
  end

  test "live stop expands an early receipt and requires durable subreaper proof afterward",
       context do
    {task, _cancel_ref, started} = launch(context, "descendant")
    descendant = descendant_pid!(context)
    _observed = descendant_scope!(started, descendant)
    persisted_start = started |> Jason.encode!() |> Jason.decode!()
    refute persisted_start["scope_observed"]

    cleanup = Runner.stop(persisted_start)
    assert cleanup["status"] == "confirmed", inspect(cleanup)
    assert cleanup["scope_observed"]
    assert Enum.any?(cleanup["owned_processes"], &(&1["pid"] == descendant))
    refute alive?(descendant)
    assert Task.await(task, 10_000)["status"] == "failed"

    repeated = Runner.stop(persisted_start)
    assert repeated["status"] == "confirmed"
    assert repeated["all_children_reaped"]

    proof = persisted_start["process_keeper"]["status_path"]
    retained = proof <> ".retained"
    File.rename!(proof, retained)

    try do
      unproved = Runner.stop(persisted_start)
      assert unproved["status"] == "uncertain"
      assert unproved["reason"] == "process_keeper_status_unavailable"
    after
      File.rename!(retained, proof)
    end

    assert Runner.stop(persisted_start)["status"] == "confirmed"
  end

  test "cleans every recorded owned descendant when its supervised calling Task is killed",
       context do
    {task, _cancel_ref, started} = launch(context, "descendant")
    descendant = descendant_pid!(context)
    _observed = descendant_scope!(started, descendant)
    :ok = Task.Supervisor.terminate_child(context.supervisor, task.pid)

    eventually(fn -> not alive?(started["os_pid"]) and not alive?(descendant) end)
    Task.ignore(task)
  end

  test "cancels when the infrastructure owner dies, even with a surviving TaskSupervisor",
       context do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {task, _cancel_ref, started} = launch(context, "descendant", owner_pid: owner)
    descendant = descendant_pid!(context)
    started = descendant_scope!(started, descendant)
    Process.exit(owner, :kill)
    receipt = Task.await(task, 10_000)

    assert Process.alive?(context.supervisor)
    assert receipt["status"] == "cancelled"
    assert receipt["error"] == "owner_down"
    assert receipt["cancellation"] == "confirmed"
    refute alive?(started["os_pid"])
    refute alive?(descendant)
  end

  test "kernel reaping confirms physical cleanup despite partial persisted history", context do
    {task, _cancel_ref, started} = launch(context, "descendant")
    descendant = descendant_pid!(context)
    observed = descendant_scope!(started, descendant)

    incomplete =
      observed
      |> Map.put("owned_processes_complete", false)
      |> Map.put("scope_error", "ownership_scan_bound")

    cleanup = Runner.stop(incomplete)
    assert cleanup["status"] == "confirmed"
    assert cleanup["all_children_reaped"]
    assert cleanup["keeper_terminated"]
    assert cleanup["scope_error"] == "ownership_scan_bound"
    refute cleanup["owned_processes_complete"]
    refute alive?(started["os_pid"])
    refute alive?(descendant)
    assert Task.await(task, 10_000)["status"] == "failed"
  end

  test "bounds a blocking scope persistence callback without losing cleanup", context do
    receipt =
      Runner.run(
        context.mix,
        probe_args("hold"),
        options(context,
          timeout_ms: 2_000,
          on_scope: fn _receipt -> Process.sleep(:infinity) end
        )
      )

    assert receipt["status"] == "timed_out", receipt_failure(receipt)
    assert receipt["on_scope"] == "timed_out"
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["cleanup"]["port_reaped"]
    refute alive?(receipt["os_pid"])
  end

  test "bounds a blocking on_start callback without losing process cleanup", context do
    receipt =
      Runner.run(
        context.mix,
        probe_args("hold"),
        options(context,
          timeout_ms: 500,
          on_start: fn _receipt -> Process.sleep(:infinity) end
        )
      )

    assert receipt["status"] == "timed_out"
    assert receipt["on_start"] == "timed_out"
    assert receipt["cleanup"]["status"] == "not_started"
    assert receipt["cleanup"]["keeper_terminated"]
    assert receipt["cleanup"]["port_reaped"]
    refute receipt["command_started"]
    assert receipt["effect"] == "not_started"
    refute alive?(receipt["os_pid"])
    refute File.exists?(Path.join(context.root, "_build"))
    assert receipt["duration_ms"] < 10_000
  end

  test "does not start a child for an already-dead infrastructure owner", context do
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}

    receipt =
      Runner.run(context.mix, probe_args("hold"), options(context, owner_pid: owner))

    assert receipt["status"] == "cancelled"
    assert receipt["error"] == "owner_down"
    assert receipt["os_pid"] == nil
    assert receipt["cleanup"]["status"] == "not_started"
  end

  test "reports unavailable executables and supervision helpers without launching", context do
    missing = Path.join(context.root, "not-an-executable")
    assert Runner.available(missing) == {:error, :unavailable}

    for {executable, opts} <- [
          {missing, options(context)},
          {context.mix, options(context, setsid_executable: missing)},
          {context.mix, options(context, candidate_python_executable: missing)},
          {context.mix, options(context, kill_executable: missing)}
        ] do
      receipt = Runner.run(executable, probe_args("hold"), opts)
      assert receipt["status"] == "unavailable"
      assert receipt["os_pid"] == nil
      assert receipt["exit_status"] == nil
      assert receipt["cleanup"]["status"] == "not_started"
      assert receipt["resources"]["status"] == "unknown"
      assert receipt["resources"]["sample_count"] == 0
      assert receipt["resources"]["observed_peak_rss_bytes"] == nil
      assert receipt["resources"]["observed_cpu_ticks"] == nil
      assert receipt["output_bytes"] == 0
      assert Jason.encode!(receipt)
    end
  end

  defp options(context, overrides \\ []) do
    Keyword.merge(
      [cwd: context.root, env: context.env, timeout_ms: 20_000, max_output_bytes: 65_536],
      overrides
    )
  end

  defp probe_args(mode), do: ["run", "--no-compile", "--no-start", "probe.exs", mode]

  defp launch(context, mode, overrides \\ []) do
    parent = self()
    cancel_ref = make_ref()

    opts =
      options(
        context,
        Keyword.merge(
          [
            cancel_ref: cancel_ref,
            on_start: fn receipt ->
              send(parent, {:started, receipt})
              :ok
            end,
            on_scope: fn receipt ->
              send(parent, {:scope, receipt["launch_id"], receipt})
              :ok
            end
          ],
          overrides
        )
      )

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Runner.run(context.mix, probe_args(mode), opts)
      end)

    assert_receive {:started, started}, 5_000
    assert started["status"] == "running"
    {task, cancel_ref, started}
  end

  defp descendant_pid!(context) do
    path = Path.join(context.root, "descendant.pid")
    eventually(fn -> File.regular?(path) and File.read!(path) != "" end)
    path |> File.read!() |> String.to_integer()
  end

  defp descendant_scope!(started, descendant) do
    descendant_scope!(started, descendant, System.monotonic_time(:millisecond) + 10_000)
  end

  defp descendant_scope!(started, descendant, deadline) do
    generation = started["launch_id"]

    receive do
      {:scope, ^generation, observed} ->
        if Enum.any?(observed["owned_processes"], &(&1["pid"] == descendant)) do
          assert observed["scope_observed"]
          assert observed["owned_processes_complete"], receipt_failure(observed)

          member = Enum.find(observed["owned_processes"], &(&1["pid"] == descendant))
          assert member["boot_id"] == started["process_identity"]["boot_id"]
          assert member["start_time"] =~ ~r/^\d+$/
          {:ok, stat} = File.read("/proc/#{descendant}/stat")
          [_stat, fields] = Regex.run(~r/^\d+ \(.*\) (.*)$/s, stat)
          assert member["start_time"] == Enum.at(String.split(fields), 19)
          assert is_integer(member["process_group"])
          assert is_integer(member["session"])
          observed
        else
          descendant_scope!(started, descendant, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("live OS descendant #{descendant} never entered the launch's observed ownership")
    end
  end

  defp term_ignored?(pid) do
    with {:ok, status} <- File.read("/proc/#{pid}/status"),
         [_line, mask] <- Regex.run(~r/^SigIgn:\s+([[:xdigit:]]+)$/m, status),
         {ignored, ""} <- Integer.parse(mask, 16) do
      rem(div(ignored, 16_384), 2) == 1
    else
      _unverified -> false
    end
  end

  defp receipt_failure(receipt) do
    "real child receipt:\n" <>
      inspect(
        Map.take(
          receipt,
          ~w(
            status error exit_status launcher_exit_status command_started dispatch
            output output_bytes output_complete truncated
            cleanup resources owned_processes scope_observed owned_processes_complete scope_error
          )
        ),
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )
  end

  defp alive?(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not Regex.match?(~r/^\d+ \(.*\) [ZX] /s, stat)
      {:error, :enoent} -> false
      {:error, :esrch} -> false
    end
  end

  defp alive?(_pid), do: false

  defp eventually(predicate),
    do: eventually(predicate, System.monotonic_time(:millisecond) + 10_000)

  defp eventually(predicate, deadline) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("real child process did not reach the expected lifecycle state")
      else
        receive do
        after
          10 -> eventually(predicate, deadline)
        end
      end
    end
  end

  defp probe_source do
    ~S"""
    case System.argv() do
      ["inspect"] ->
        secret = System.fetch_env!("RUNNER_EXPLICIT_SECRET")
        midpoint = div(byte_size(secret), 2)
        IO.binwrite(binary_part(secret, 0, midpoint))
        Process.sleep(40)
        IO.binwrite(binary_part(secret, midpoint, byte_size(secret) - midpoint))
        IO.puts("")
        IO.puts("ambient=#{System.get_env("DOCS_RUNNER_AMBIENT_TEST_SECRET", "absent")}")
        IO.puts("stdin=#{inspect(IO.read(:stdio, :eof))}")
        IO.binwrite(<<255, 254, 10>>)

      ["cwd"] ->
        IO.puts(File.cwd!())

      ["flood"] ->
        chunk = String.duplicate("0123456789", 1_024)
        Enum.each(1..100_000, fn _ -> IO.binwrite(chunk) end)

      ["prefix"] ->
        secret = System.fetch_env!("RUNNER_EXPLICIT_SECRET")
        IO.binwrite(binary_part(secret, 0, 16))
        Process.sleep(40)
        IO.binwrite("|")
        Process.sleep(:infinity)

      ["resources"] ->
        {:ok, _applications} = Application.ensure_all_started(:crypto)
        payload = :binary.copy("resource-memory-sample", 1_048_576)
        deadline = System.monotonic_time(:millisecond) + 1_000

        hash = fn recurse ->
          digest = :crypto.hash(:sha256, payload)

          if System.monotonic_time(:millisecond) < deadline,
            do: recurse.(recurse),
            else: digest
        end

        digest = hash.(hash)
        IO.puts("resource-workload bytes=#{byte_size(payload)} digest=#{Base.encode16(digest)}")

      [mode] when mode in ["listener", "wildcard_listener"] ->
        ip = if mode == "listener", do: {127, 0, 0, 1}, else: {0, 0, 0, 0}
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: ip, reuseaddr: false])
        {:ok, {_ip, port}} = :inet.sockname(listener)
        File.write!("listener.port", Integer.to_string(port))
        Process.sleep(:infinity)

      ["descendant_listener"] ->
        elixir = System.find_executable("elixir") || raise "elixir unavailable"
        source = ~S'''
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, {_ip, port}} = :inet.sockname(listener)
        File.write!("listener.port", Integer.to_string(port))
        Process.sleep(:infinity)
        '''
        port = Port.open({:spawn_executable, String.to_charlist(elixir)}, [
          :binary, :in, :exit_status, :use_stdio, {:args, ["-e", source]}
        ])
        {:os_pid, pid} = Port.info(port, :os_pid)
        File.write!("descendant.pid", Integer.to_string(pid))
        Process.sleep(:infinity)

      ["hold"] ->
        Process.sleep(:infinity)

      ["stubborn"] ->
        sh = System.find_executable("sh") || raise "sh unavailable"
        sleep = System.find_executable("sleep") || raise "sleep unavailable"
        port = Port.open({:spawn_executable, String.to_charlist(sh)}, [
          :binary, :in, :exit_status, :use_stdio,
          {:args, ["-c", "trap '' TERM; exec \"$1\" 60", "docs-stubborn", sleep]}
        ])
        {:os_pid, pid} = Port.info(port, :os_pid)
        File.write!("descendant.pid", Integer.to_string(pid))
        Process.sleep(:infinity)

      [mode] when mode in ["descendant", "orphan"] ->
        sleep = System.find_executable("sleep") || raise "sleep unavailable"
        port = Port.open({:spawn_executable, String.to_charlist(sleep)}, [
          :binary, :in, :exit_status, :use_stdio, {:args, ["60"]}
        ])
        {:os_pid, pid} = Port.info(port, :os_pid)
        File.write!("descendant.pid", Integer.to_string(pid))
        if mode == "orphan", do: System.halt(0), else: Process.sleep(:infinity)
    end
    """
  end
end
