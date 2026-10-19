defmodule OhMyJido.ProcessControlTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.Runtime

  setup do
    root =
      Path.join(System.tmp_dir!(), "omj-process-control-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "native ReAct cancellation reaches the real Shell process without waiting for the Action deadline",
       %{root: root} do
    session = session(root)
    run = running_shell(session, "Cancel a running shell")
    child = ready_child(root)
    assert alive?(child)
    started = System.monotonic_time(:millisecond)
    assert :ok = OhMyJido.cancel(session, run)

    assert {:error, %{status: :cancelled, error: {:cancelled, :user_cancelled}}} =
             OhMyJido.await(session, run, timeout: 5_000)

    assert System.monotonic_time(:millisecond) - started < 5_000
    wait_until(fn -> not alive?(child) end)
    assert File.read!(Path.join(root, "effect")) == "written-once\n"
    assert_uncertain_shell(session)

    follow_up =
      expect_react do
        user("Continue without repeating the effect")
        answer("The interrupted effect was not replayed.")
      end

    assert {:ok, follow_up_run} =
             OhMyJido.prompt(
               session,
               "Continue without repeating the effect",
               react_opts(follow_up)
             )

    assert {:ok, %{status: :completed}} = OhMyJido.await(session, follow_up_run)
    assert File.read!(Path.join(root, "effect")) == "written-once\n"
  end

  test "suspending a native run cleans its Shell children while preserving uncertain writes", %{
    root: root
  } do
    session = session(root)
    run = running_shell(session, "Suspend a running shell")
    child = ready_child(root)
    assert :ok = OhMyJido.suspend(session, run)

    assert {:error, %{status: :suspended, error: {:cancelled, :suspended}}} =
             OhMyJido.await(session, run, timeout: 5_000)

    wait_until(fn -> not alive?(child) end)
    assert_uncertain_shell(session)
    assert :ok = OhMyJido.resume(session)
    assert File.read!(Path.join(root, "effect")) == "written-once\n"
  end

  test "a coding-run deadline cancels subprocess resources before their own longer deadline", %{
    root: root
  } do
    session = session(root, run_timeout_ms: 2_000)
    run = running_shell(session, "Run until the coordinator deadline")
    child = ready_child(root)

    assert {:error, %{status: :timed_out, error: {:cancelled, :deadline}}} =
             OhMyJido.await(session, run, timeout: 5_000)

    wait_until(fn -> not alive?(child) end)
    assert_uncertain_shell(session)
  end

  test "session stop releases the actual operating-system tree", %{root: root} do
    session = session(root)
    _run = running_shell(session, "Stop a session with a running shell")
    child = ready_child(root)
    assert :ok = OhMyJido.stop_session(session)
    wait_until(fn -> not alive?(child) end)
    assert File.read!(Path.join(root, "effect")) == "written-once\n"
  end

  test "coordinator death also kills the independently supervised Action's subprocess", %{
    root: root
  } do
    session = session(root)
    _run = running_shell(session, "Crash a coordinator with a running shell")
    child = ready_child(root)
    coordinator = GenServer.whereis(Runtime.via(session))
    assert is_pid(coordinator)
    Process.exit(coordinator, :kill)
    wait_until(fn -> not alive?(child) end)
    assert File.read!(Path.join(root, "effect")) == "written-once\n"
  end

  test "Shell output automatically reaches bounded redacted typed events and preserves a trusted callback",
       %{root: root} do
    session = session(root)
    {:ok, context} = OhMyJido.Session.call(session, :context)
    secret = "stream-fixture-secret"
    :ok = OhMyJido.Session.register_secrets(context.coordinator, [secret])
    :ok = OhMyJido.subscribe(session, self())

    assert {:ok, %{stdout: ^secret, stderr: "diagnostic"}} =
             OhMyJido.Process.run(
               context,
               "sh",
               ["-c", "printf '%s' \"$OMJ_STREAM_FIXTURE\"; printf diagnostic >&2"],
               env: %{"OMJ_STREAM_FIXTURE" => secret},
               on_output: self(),
               max_output_bytes: 64
             )

    assert collect_stream(:stdout, []) |> IO.iodata_to_binary() == secret
    events = OhMyJido.events(session)

    stdout =
      for %{kind: :tool_output, payload: %{stream: :stdout, text: text}} <- events,
          into: "",
          do: text

    stderr =
      for %{kind: :tool_output, payload: %{stream: :stderr, text: text}} <- events,
          into: "",
          do: text

    assert stdout == "[REDACTED]"
    assert stderr == "diagnostic"
    refute inspect(events) =~ secret
    assert Enum.map(events, & &1.seq) == Enum.sort(Enum.uniq(Enum.map(events, & &1.seq)))
  end

  defp collect_stream(stream, acc) do
    receive do
      {:oh_my_jido_process_output, _ref, ^stream, chunk} -> collect_stream(stream, [chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp session(root, opts \\ []) do
    runtime = __MODULE__.Host

    start_supervised!(
      {Runtime,
       Keyword.merge(
         [
           name: runtime,
           allow_test_scripts: true,
           tool_timeout_ms: 20_000,
           run_timeout_ms: 30_000,
           max_processes: 1
         ],
         opts
       )}
    )

    {:ok, session} =
      OhMyJido.start_session(runtime,
        workspace: root,
        permissions: [:exec],
        tools: [OhMyJido.Tools.Shell]
      )

    session
  end

  defp running_shell(session, task) do
    script =
      expect_react do
        user(task)

        call("shell", %{
          executable: "sh",
          args: ["-c", "printf 'written-once\\n' >> effect; sleep 30 & echo $! > child; wait"],
          timeout_ms: 15_000
        })

        answer("The shell exited.")
      end

    {:ok, run} = OhMyJido.prompt(session, task, react_opts(script))
    run
  end

  defp ready_child(root) do
    path = Path.join(root, "child")
    wait_until(fn -> match?({:ok, content} when content != "", File.read(path)) end)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp assert_uncertain_shell(session) do
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)

    assert Enum.any?(effects, fn
             {_id, %{name: "shell", status: :uncertain}} -> true
             {_id, %{name: "shell", result: {:ok, %{effect: :uncertain}}}} -> true
             _other -> false
           end)
  end

  defp wait_until(predicate, attempts \\ 500)

  defp wait_until(_predicate, 0),
    do: flunk("native subprocess did not reach the required lifecycle boundary")

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      receive do
      after
        10 -> wait_until(predicate, attempts - 1)
      end
    end
  end

  defp alive?(pid) do
    case OhMyJido.Process.capture_identity(pid) do
      {:ok, %{state: state}} -> state not in ["Z", "X"]
      {:error, reason} when reason in [:enoent, :esrch] -> false
      {:error, reason} -> flunk("cannot observe child cleanup: #{inspect(reason)}")
    end
  end
end
