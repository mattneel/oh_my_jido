defmodule OhMyJido.ProcessTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Tool}
  alias OhMyJido.Process, as: Runner

  defmodule Policy do
    def authorize(_context, capability, effect, opts) do
      send(opts[:observer], {:authorization, capability, effect})
      if opts[:deny], do: {:error, :host_denied}, else: :ok
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %Context{
      session_id: "process-test",
      workspace: root,
      permissions: MapSet.new([:exec]),
      host: {Policy, observer: self()}
    }

    %{root: root, context: context}
  end

  test "real commands preserve distinct streams, exit code and child-scoped cwd/env", %{
    root: root,
    context: context
  } do
    cwd = File.cwd!()
    old_env = System.get_env("OMJ_PROCESS_FIXTURE")
    File.mkdir_p!(Path.join(root, "nested"))

    assert {:ok, result} =
             Runner.run(
               context,
               "sh",
               ["-c", "printf '%s' \"$OMJ_PROCESS_FIXTURE\"; printf 'failure' >&2; pwd; exit 7"],
               cwd: "nested",
               env: %{"OMJ_PROCESS_FIXTURE" => "child-value"}
             )

    assert result.status == :exited
    assert result.exit_status == 7
    assert result.stdout == "child-value#{Path.join(root, "nested")}\n"
    assert result.stderr == "failure"
    assert result.cleanup == :confirmed
    assert result.effect == :completed
    assert File.cwd!() == cwd
    assert System.get_env("OMJ_PROCESS_FIXTURE") == old_env

    assert_receive {:authorization, :exec,
                    %{
                      executable: _,
                      args: ["-c", _],
                      cwd: _,
                      env: %{"OMJ_PROCESS_FIXTURE" => "child-value"}
                    }}
  end

  test "stream delivery and retained output are bounded independently for both streams", %{
    context: context
  } do
    assert {:ok, result} =
             Runner.run(
               context,
               "sh",
               [
                 "-c",
                 "i=0; while [ \"$i\" -lt 2000 ]; do printf '0123456789'; printf 'abcdefghij' >&2; i=$((i+1)); done"
               ],
               max_output_bytes: 96,
               on_output: self()
             )

    assert byte_size(result.stdout) == 96
    assert byte_size(result.stderr) == 96
    assert result.truncated
    assert result.output_bytes.stdout == 20_000
    assert result.output_bytes.stderr == 20_000
    events = collect_output([])

    assert events
           |> Enum.filter(&(elem(&1, 0) == :stdout))
           |> Enum.map(&elem(&1, 1))
           |> IO.iodata_length() == 96

    assert events
           |> Enum.filter(&(elem(&1, 0) == :stderr))
           |> Enum.map(&elem(&1, 1))
           |> IO.iodata_length() == 96
  end

  test "explicit cancellation kills a shell child tree but never claims effects were undone", %{
    root: root,
    context: context
  } do
    script =
      "printf 'already-written' > effect; sh -c 'sleep 30 & echo $! > grandchild; wait' & echo $! > child; wait"

    assert {:ok, handle} = Runner.start(context, "sh", ["-c", script], timeout: 10_000)
    wait_for_file(Path.join(root, "grandchild"))
    wait_for_file(Path.join(root, "child"))
    child = root |> Path.join("child") |> File.read!() |> String.trim() |> String.to_integer()

    grandchild =
      root |> Path.join("grandchild") |> File.read!() |> String.trim() |> String.to_integer()

    assert {:ok, cancelled} = Runner.cancel(handle)
    assert cancelled.status == :cancelled
    assert cancelled.cancellation == :confirmed
    assert cancelled.cleanup == :confirmed
    assert cancelled.effect == :uncertain
    assert {:ok, ^cancelled} = Runner.await(handle)
    refute alive?(child)
    refute alive?(grandchild)
    assert File.read!(Path.join(root, "effect")) == "already-written"
  end

  test "deadline cleanup reaches descendants and returns partial output", %{
    root: root,
    context: context
  } do
    assert {:ok, result} =
             Runner.run(context, "sh", ["-c", "printf ready; sleep 30 & echo $! > child; wait"],
               timeout: 150
             )

    child = root |> Path.join("child") |> File.read!() |> String.trim() |> String.to_integer()
    assert result.status == :timed_out
    assert result.stdout == "ready"
    assert result.cleanup == :confirmed
    assert result.effect == :uncertain
    refute alive?(child)
  end

  test "monitored caller teardown releases its operating-system descendants", %{
    root: root,
    context: context
  } do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} =
          Runner.start(context, "sh", ["-c", "sleep 30 & echo $! > child; wait"],
            timeout: 10_000,
            observer: parent
          )

        send(parent, {:handle, handle})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:handle, handle}, 2_000
    wait_for_file(Path.join(root, "child"))
    child = root |> Path.join("child") |> File.read!() |> String.trim() |> String.to_integer()
    Process.exit(owner, :kill)
    assert_receive {:oh_my_jido_process, ref, {:ok, result}}, 5_000
    assert ref == handle.ref
    assert result.status == :owner_down
    assert result.cleanup == :confirmed
    assert result.effect == :uncertain
    refute alive?(child)
  end

  test "an exited root does not leave background children holding its output pipes", %{
    root: root,
    context: context
  } do
    assert {:ok, result} =
             Runner.run(context, "sh", ["-c", "sleep 30 & echo $! > child; printf done"],
               timeout: 2_000
             )

    child = root |> Path.join("child") |> File.read!() |> String.trim() |> String.to_integer()
    assert result.status == :exited
    assert result.stdout == "done"
    assert result.cleanup == :confirmed
    refute alive?(child)
  end

  test "permissions, host denial, escaped cwd and invalid arguments prevent launches", %{
    root: root,
    context: context
  } do
    denied = %{context | permissions: MapSet.new()}

    assert {:error, {:permission_denied, :exec}} =
             Runner.run(denied, "sh", ["-c", "touch denied"])

    assert {:error, :host_denied} =
             Runner.run(%{context | host: {Policy, observer: self(), deny: true}}, "sh", [
               "-c",
               "touch denied"
             ])

    assert {:error, _} = Runner.run(context, "sh", ["-c", "touch denied"], cwd: "..")
    assert {:error, _} = Runner.run(context, "sh", ["\0"])
    refute File.exists?(Path.join(root, "denied"))
  end

  test "shared cleanup rejects stale Linux identity instead of signaling a reused process", %{
    root: root,
    context: context
  } do
    script =
      "printf '%s\\n' \"$$\" > leader; printf '%s\\n' \"$PPID\" > parent; sleep 30 & echo $! > child; wait"

    assert {:ok, handle} = Runner.start(context, "sh", ["-c", script], timeout: 10_000)
    wait_for_file(Path.join(root, "leader"))
    wait_for_file(Path.join(root, "parent"))
    leader = root |> Path.join("leader") |> File.read!() |> String.trim() |> String.to_integer()
    assert {:ok, identity} = Runner.capture_identity(leader)
    assert identity.group == Integer.to_string(leader)
    assert identity.session == identity.group
    assert identity.parent == root |> Path.join("parent") |> File.read!() |> String.trim()

    assert {:error, :cleanup_uncertain} =
             Runner.terminate_group(leader, %{identity | start: identity.start <> "0"})

    assert alive?(leader)
    assert {:ok, %{cleanup: :confirmed}} = Runner.cancel(handle)
  end

  test "post-authorization preconditions reject the effect before the executable starts", %{
    root: root,
    context: context
  } do
    assert {:error, :changed_rules} =
             Runner.run(context, "sh", ["-c", "touch forbidden"],
               before_effect: fn -> {:error, :changed_rules} end
             )

    refute File.exists?(Path.join(root, "forbidden"))
    assert_receive {:authorization, :exec, %{args: ["-c", "touch forbidden"]}}
  end

  test "native runtime admission refuses excess processes rather than launching hidden work", %{
    root: root,
    context: context
  } do
    runtime = __MODULE__.Capacity
    start_supervised!({OhMyJido.Runtime, name: runtime, max_processes: 1})
    context = %{context | runtime: runtime}

    assert {:ok, handle} =
             Runner.start(context, "sh", ["-c", "sleep 30 & echo $! > child; wait"],
               timeout: 10_000
             )

    monitor = Process.monitor(handle.pid)
    assert {:error, {:capacity, :process}} = Runner.start(context, "sh", ["-c", "touch excess"])
    refute File.exists?(Path.join(root, "excess"))
    assert {:ok, %{cleanup: :confirmed}} = Runner.cancel(handle)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000
  end

  test "normal completion invokes bounded function output callbacks in the caller", %{
    context: context
  } do
    owner = self()
    callback = fn stream, chunk -> send(owner, {:callback, self(), stream, chunk}) end

    assert {:ok, %{stdout: "visible"}} =
             Runner.run(context, "printf", ["visible"], on_output: callback)

    assert collect_callbacks(owner, []) |> IO.iodata_to_binary() == "visible"
  end

  test "trusted read-only launches work without granting model-facing shell execution", %{
    context: context
  } do
    context = %{context | permissions: MapSet.new([:read]), tools: [OhMyJido.Tools.Shell]}

    assert {:ok, %{stdout: "read-only"}} =
             Runner.run(context, "printf", ["read-only"], capability: :read)

    assert_receive {:authorization, :read, %{executable: _, args: ["read-only"]}}

    assert {:error, _} =
             Tool.execute(context, "shell", %{
               executable: "printf",
               args: ["forbidden"],
               capability: :read
             })
  end

  test "the shell Action validates and executes a real nonzero command through Jido", %{
    context: context
  } do
    context = %{context | tools: [OhMyJido.Tools.Shell]}

    assert {:ok, %{stdout: "output", stderr: "diagnostic", exit_status: 3}} =
             Tool.execute(context, "shell", %{
               executable: "sh",
               args: ["-c", "printf output; printf diagnostic >&2; exit 3"]
             })

    assert {:error, _} = Tool.execute(context, "shell", %{executable: "sh", timeout_ms: -1})
  end

  defp collect_callbacks(owner, acc) do
    receive do
      {:callback, ^owner, :stdout, chunk} -> collect_callbacks(owner, [chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_output(acc) do
    receive do
      {:oh_my_jido_process_output, _ref, stream, data} -> collect_output([{stream, data} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp wait_for_file(path, attempts \\ 200)
  defp wait_for_file(_path, 0), do: flunk("child did not reach the observable ready boundary")

  defp wait_for_file(path, attempts) do
    if match?({:ok, contents} when contents != "", File.read(path)) do
      :ok
    else
      receive do
        :unrelated_fixture_message -> :ok
      after
        10 -> wait_for_file(path, attempts - 1)
      end
    end
  end

  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not Regex.match?(~r/^\d+ \(.*\) [ZX] /, stat)
      {:error, reason} when reason in [:enoent, :esrch] -> false
      {:error, reason} -> flunk("cannot observe child termination: #{inspect(reason)}")
    end
  end
end
