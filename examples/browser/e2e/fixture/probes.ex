defmodule OhMyJidoBrowser.Probes do
  @moduledoc """
  Network-free capability checks executed by the end-to-end browser VM build.

  Only model responses are scripted. Sessions, native agents, tools, checkpoints,
  approvals, delegation and telemetry use the public library API. Each row owns
  a supervised runtime tree and workspace, including when it fails or times out.
  """

  alias Jido.AI.Test.ReActScript
  alias OhMyJido.{Context, Prompt, Tools}

  @deadline 25_000
  @wait_timeout 8_000
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PzWvWQAAAABJRU5ErkJggg=="
  @rows [
    {"A03", "Multi-instance isolation"},
    {"A05", "Control"},
    {"A06", "Durable sessions"},
    {"A07", "Fault recovery"},
    {"A08", "Bounded concurrency"},
    {"B02", "Model roles"},
    {"B09", "Context policy"},
    {"B10", "Project instructions"},
    {"C07", "Structural code work"},
    {"C11", "Image/artifact inputs"},
    {"C13", "Headless live Observer"},
    {"D01", "Subagents"},
    {"D02", "Parallel exploration"},
    {"D04", "Parent control"},
    {"D05", "Checkpoints"},
    {"D06", "Task memory"},
    {"D07", "Skills and rules"},
    {"D08", "Custom tools"},
    {"D14", "Iterative experiments"},
    {"F03", "Observability"},
    {"L1", "Process tools fail closed"}
  ]

  defmodule ApproveHost do
    @moduledoc "Approves every effect, so a probe reaches the effect itself."
    @behaviour OhMyJido.Host

    @impl true
    def authorize(_context, _capability, _effect, _opts), do: :ok

    @impl true
    def credentials(_context, _account, _opts), do: {:error, :no_credentials_in_probes}

    @impl true
    def invoke(_context, _service, _request, _opts), do: {:error, :no_services_in_probes}

    @impl true
    def question(_context, _question, _opts), do: :pending
  end

  defmodule Echo do
    @moduledoc "A host-authored Action used to prove idle tool registration."
    use Jido.Action,
      name: "browser_probe_echo",
      description: "Return the supplied value under the session's custom grant",
      schema: Zoi.object(%{value: Zoi.string()})

    @doc false
    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{value: value}, context) do
      with :ok <- OhMyJido.Tool.authorize(context, :custom) do
        {:ok, %{echo: value}}
      end
    end
  end

  @doc "Runs every capability row sequentially, isolating failures and deadlines."
  @spec run(String.t()) :: [
          %{
            id: String.t(),
            capability: String.t(),
            status: :passed | :failed,
            detail: String.t(),
            ms: non_neg_integer()
          }
        ]
  def run(root), do: Enum.map(@rows, &run_row(root, &1))

  @doc false
  @spec handle_telemetry([atom()], map(), map(), {pid(), String.t(), reference()}) :: :ok
  def handle_telemetry(_event, _measurements, metadata, {owner, session_id, token}) do
    if metadata.session_id == session_id do
      send(owner, {:probe_telemetry, token, metadata.kind})
    end

    :ok
  end

  defp run_row(root, {id, capability}) do
    started = System.monotonic_time(:millisecond)
    outcome = protect(fn -> isolated_probe(root, id) end)

    %{
      id: id,
      capability: capability,
      status: if(passed?(outcome), do: :passed, else: :failed),
      detail: detail(outcome),
      ms: max(System.monotonic_time(:millisecond) - started, 0)
    }
  end

  defp isolated_probe(root, id) do
    {:ok, supervisor} = Supervisor.start_link([{Task.Supervisor, []}], strategy: :one_for_one)
    scope = %{supervisor: supervisor, root: root, id: id, token: make_ref()}

    try do
      [{Task.Supervisor, tasks, :supervisor, _modules}] = Supervisor.which_children(supervisor)
      task = Task.Supervisor.async_nolink(tasks, fn -> run_probe_task(scope) end)
      task_result(task)
    after
      stop_scope(scope)
    end
  end

  defp run_probe_task(scope), do: protect(fn -> probe(scope.id, scope) end)

  defp task_result(task) do
    case Task.yield(task, @deadline) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        mismatch({:probe_exit, reason})

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "Probe exceeded #{@deadline} ms"}
    end
  end

  defp stop_scope(scope) do
    :telemetry.detach({__MODULE__, scope.token})
    protect(fn -> stop_sessions(scope.supervisor) end)
    protect(fn -> Supervisor.stop(scope.supervisor, :normal, 10_000) end)
    :ok
  end

  defp stop_sessions(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.reject(fn {id, _pid, _type, _modules} -> id == Task.Supervisor end)
    |> Enum.each(fn {runtime, _pid, _type, _modules} -> stop_runtime_sessions(runtime) end)
  end

  defp stop_runtime_sessions(runtime) do
    runtime
    |> OhMyJido.list_sessions()
    |> Enum.each(fn session -> protect(fn -> OhMyJido.stop_session(session) end) end)
  end

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> mismatch({kind, reason})
  end

  defp passed?(:ok), do: true
  defp passed?({:ok, observed}), do: is_binary(observed)
  defp passed?(_outcome), do: false

  defp detail(:ok), do: "Public behaviour and observable outcomes matched."
  defp detail({:ok, observed}) when is_binary(observed), do: observed
  defp detail({:error, message}) when is_binary(message), do: message
  defp detail(other), do: inspect(other, limit: 12, printable_limit: 600)
  defp mismatch(other), do: {:error, "Unexpected outcome: #{detail(other)}"}
  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp runtime(scope, suffix \\ "Main", opts \\ []) do
    unique = System.unique_integer([:positive])
    name = Module.concat([__MODULE__, Runtime, scope.id, suffix <> Integer.to_string(unique)])
    options = Keyword.merge([name: name, allow_test_scripts: true], opts)
    {:ok, pid} = Supervisor.start_child(scope.supervisor, {OhMyJido, options})
    {name, pid}
  end

  defp session(scope, runtime, opts \\ []) do
    path = Path.join(scope.root, "probe-#{scope.id}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    options = Keyword.merge([workspace: path, permissions: [], tools: []], opts)
    OhMyJido.start_session(runtime, options)
  end

  defp script(prompt, turns) do
    %{user: prompt, turns: turns}
    |> ReActScript.new()
    |> ReActScript.react_opts()
  end

  defp answer(text), do: %{type: :answer, text: text}
  defp call(name, arguments), do: %{type: :tool_call, name: name, arguments: arguments}

  defp answer_run(session, prompt, text, opts \\ []) do
    with {:ok, run} <- OhMyJido.prompt(session, prompt, script(prompt, [answer(text)]) ++ opts),
         {:ok, %{status: :completed, answer: ^text}} <-
           OhMyJido.await(session, run, timeout: @wait_timeout) do
      :ok
    else
      other -> mismatch(other)
    end
  end

  defp question_run(session, prompt) do
    turns = [call("question", %{question: "May this probe continue?"}), answer("Approved.")]

    with {:ok, run} <- OhMyJido.prompt(session, prompt, script(prompt, turns)),
         {:ok, event} <- wait_event(session, :approval_requested) do
      {:ok, run, event.payload.id}
    else
      other -> mismatch(other)
    end
  end

  defp wait_event(session, kind) do
    wait_event(session, kind, System.monotonic_time(:millisecond) + @wait_timeout)
  end

  defp wait_event(session, kind, deadline) do
    case Enum.find(OhMyJido.events(session), &(&1.kind == kind)) do
      nil -> retry_event(session, kind, deadline)
      event -> {:ok, event}
    end
  end

  defp retry_event(session, kind, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      wait_event(session, kind, deadline)
    else
      {:error, "No #{kind} event before deadline"}
    end
  end

  defp probe("A03", scope), do: isolation(scope)
  defp probe("A05", scope), do: control(scope)
  defp probe("A06", scope), do: durable(scope)
  defp probe("A07", scope), do: recovery(scope)
  defp probe("A08", scope), do: capacity(scope)
  defp probe("B02", scope), do: model_role(scope)
  defp probe("B09", scope), do: compaction(scope)
  defp probe("B10", _scope), do: instructions()
  defp probe("C07", scope), do: structural(scope)
  defp probe("C11", scope), do: artifact(scope)
  defp probe("C13", scope), do: observer(scope)
  defp probe("D01", scope), do: subagent(scope)
  defp probe("D02", scope), do: parallel_children(scope)
  defp probe("D04", scope), do: child_control(scope)
  defp probe("D05", scope), do: checkpoints(scope)
  defp probe("D06", scope), do: memory(scope)
  defp probe("D07", scope), do: skills(scope)
  defp probe("D08", scope), do: custom_tool(scope)
  defp probe("D14", scope), do: experiments(scope)
  defp probe("F03", scope), do: observability(scope)
  defp probe("L1", scope), do: processes_unavailable(scope)

  # Rows C04, C05 and C06 need OS processes. In the page they must end in a
  # typed error, not hang, crash the session or pretend to succeed.
  defp processes_unavailable(scope) do
    {runtime, _pid} = runtime(scope)

    options = [
      permissions: [:read, :git, :exec],
      tools: [Tools.Search, Tools.Git, Tools.Shell],
      host: {ApproveHost, []}
    ]

    with {:ok, session} <- session(scope, runtime, options),
         {:ok, search} <- typed_failure(OhMyJido.execute_tool(session, "search", %{pattern: "x"})),
         {:ok, git} <-
           typed_failure(OhMyJido.execute_tool(session, "git", %{operation: "status"})),
         {:ok, shell} <-
           typed_failure(
             OhMyJido.execute_tool(session, "shell", %{executable: "sh", args: ["-c", "true"]})
           ),
         {:ok, %{status: :idle}} <- OhMyJido.inspect_session(session) do
      {:ok, "search #{search}; git #{git}; shell #{shell}; session still idle"}
    else
      other -> mismatch(other)
    end
  end

  defp typed_failure({:error, reason}) when not is_nil(reason),
    do: {:ok, inspect(reason, limit: 8, printable_limit: 160)}

  defp typed_failure(other), do: {:error, "Expected a typed error, got: #{detail(other)}"}

  # Mirrors test/context_policy_test.exs:209: a tiny message budget forces
  # extractive compaction across ordinary runs, and retained facts survive it.
  defp compaction(scope) do
    {runtime, _pid} = runtime(scope, "Main", context_policy: [max_messages: 4, keep_recent: 2])

    with {:ok, session} <- session(scope, runtime),
         :ok <- OhMyJido.retain(session, %{goal: "Keep the browser port goal"}),
         :ok <- answer_run(session, "First turn", "First answer."),
         :ok <- answer_run(session, "Second turn", "Second answer."),
         :ok <- answer_run(session, "Third turn", "Third answer."),
         {:ok, %{payload: %{removed_messages: removed}}} <-
           wait_event(session, :context_compacted),
         :ok <- check(removed > 0, "compaction removed no messages"),
         {:ok, %{goal: "Keep the browser port goal"}} <- OhMyJido.inspect_session(session) do
      :ok
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/prompt_test.exs:26 and :46: host text outranks approved project
  # text, and neither unapproved project text nor task metadata gains authority.
  defp instructions do
    context = %Context{
      session_id: "probe-instructions",
      workspace: "/workspace",
      permissions: MapSet.new([:read]),
      tools: [Tools.Read],
      model: %{
        id: "probe-model",
        provider: :openai,
        capabilities: %{tools: %{enabled: true, parallel: false}},
        modalities: %{input: [:text]}
      }
    }

    task = %{goal: "Probe instruction precedence", instructions: "TASK CLAIMS HOST AUTHORITY"}

    trusted = %{
      instructions: "HOST: keep the page usable",
      project_instructions: "PROJECT: prefer small DOM edits",
      project_approved: true
    }

    untrusted = %{project_instructions: "UNTRUSTED PROJECT AUTHORITY", project_approved: false}

    with {:ok, prompt} <- Prompt.compose(context, task, trusted),
         {:ok, plain} <- Prompt.compose(context, task, untrusted),
         :ok <-
           check(prompt =~ "HOST: keep" and prompt =~ "PROJECT: prefer", "approved text missing"),
         :ok <-
           check(offset(prompt, "HOST:") < offset(prompt, "PROJECT:"), "project outranks host"),
         :ok <-
           check(not (plain =~ "UNTRUSTED" or plain =~ "TASK CLAIMS"), "unapproved text promoted") do
      :ok
    else
      other -> mismatch(other)
    end
  end

  defp offset(text, part), do: text |> :binary.match(part) |> elem(0)

  # Mirrors test/runtime_test.exs:110 and test/context_constructor_test.exs:235.
  defp isolation(scope) do
    {first_runtime, _first_pid} = runtime(scope, "Reader")
    {second_runtime, _second_pid} = runtime(scope, "Denied")

    with {:ok, first} <-
           session(scope, first_runtime, id: "same", permissions: [:read], tools: [Tools.Read]),
         {:ok, second} <-
           session(scope, second_runtime,
             id: "same",
             permissions: [:ask],
             tools: [Tools.Read, Tools.Question]
           ),
         {:ok, %{workspace: root}} <- OhMyJido.inspect_session(first),
         :ok <- File.write(Path.join(root, "input.txt"), "isolated"),
         {:ok, %{content: "isolated"}} <-
           OhMyJido.execute_tool(first, "read", %{path: "input.txt"}),
         :ok <- denied_read(OhMyJido.execute_tool(second, "read", %{path: "input.txt"})),
         :ok <- OhMyJido.stop_session(first),
         {:ok, %{status: :idle, permissions: [:ask]}} <- OhMyJido.inspect_session(second) do
      check(OhMyJido.list_sessions(second_runtime) == [second], "Second runtime lost its session")
    else
      other -> mismatch(other)
    end
  end

  defp denied_read({:error, {:permission_denied, :read}}), do: :ok
  defp denied_read({:error, %{details: %{reason: {:permission_denied, :read}}}}), do: :ok
  defp denied_read(other), do: mismatch(other)

  # Mirrors test/process_control_test.exs:15,49 and tool_call_limits_test.exs:80.
  defp control(scope) do
    {runtime, _pid} = runtime(scope)

    with :ok <- controlled_session(scope, runtime, :cancel),
         do: controlled_session(scope, runtime, :suspend)
  end

  defp controlled_session(scope, runtime, operation) do
    with {:ok, session} <-
           session(scope, runtime, permissions: [:ask], tools: [Tools.Question]),
         {:ok, run, _question} <- question_run(session, "Wait for #{operation}"),
         {:ok, %{status: :running}} <- OhMyJido.inspect_session(session),
         :ok <- OhMyJido.steer(session, run, "Do not start another tool."),
         :ok <- stop_run(session, run, operation),
         {:error, %{status: status}} <- OhMyJido.await(session, run, timeout: @wait_timeout) do
      control_result(session, operation, status)
    else
      other -> mismatch(other)
    end
  end

  defp stop_run(session, run, :cancel), do: OhMyJido.cancel(session, run)
  defp stop_run(session, run, :suspend), do: OhMyJido.suspend(session, run)
  defp control_result(_session, :cancel, :cancelled), do: :ok

  defp control_result(session, :suspend, :suspended) do
    with :ok <- OhMyJido.resume(session),
         {:ok, %{status: :idle}} <- OhMyJido.inspect_session(session) do
      :ok
    else
      other -> mismatch(other)
    end
  end

  defp control_result(_session, operation, status), do: mismatch({operation, status})

  # Mirrors test/runtime_test.exs:13 and session_recovery_test.exs:65.
  defp durable(scope) do
    {runtime, _pid} = runtime(scope)

    with {:ok, session} <- session(scope, runtime),
         :ok <- answer_run(session, "Remember this conversation", "Browser checkpoint answer."),
         :ok <- OhMyJido.checkpoint(session),
         :ok <- restart_worker(session),
         :ok <- OhMyJido.stop_session(session),
         {:ok, ^session} <- OhMyJido.resume_session(runtime, session.id),
         {:ok, %{conversation: conversation}} <- OhMyJido.inspect_session(session) do
      check(
        Enum.any?(conversation, &(Map.get(&1, :content) == "Browser checkpoint answer.")),
        "Default ETS checkpoint did not restore the assistant conversation"
      )
    else
      other -> mismatch(other)
    end
  end

  # Worker restart follows delegation_test.exs:137 and session.ex:868-880.
  defp recovery(scope) do
    {runtime, pid} = runtime(scope)

    with {:ok, session} <- session(scope, runtime),
         :ok <- restart_worker(session),
         :ok <- answer_run(session, "Continue after worker recovery", "Recovered without replay.") do
      check(Process.alive?(pid), "Worker recovery stopped the host runtime")
    else
      other -> mismatch(other)
    end
  end

  defp restart_worker(session) do
    with {:ok, %{agent_pid: original, status: :idle}} <- OhMyJido.inspect_session(session),
         true <- Process.exit(original, :kill),
         {:ok, %{payload: %{replay: false}}} <- wait_event(session, :worker_recovered),
         {:ok, %{agent_pid: replacement, status: :idle}} <- OhMyJido.inspect_session(session) do
      check(
        replacement != original and Process.alive?(replacement),
        "Native worker was not replaced"
      )
    else
      other -> mismatch(other)
    end
  end

  # Mirrors session_recovery_test.exs:301; capacity tags are runtime.ex:157-160,198-205.
  defp capacity(scope) do
    {runtime, _pid} = runtime(scope, "Bounded", max_active: 1, max_sessions: 2)

    with {:ok, first} <- session(scope, runtime, permissions: [:ask], tools: [Tools.Question]),
         {:ok, second} <- session(scope, runtime),
         {:error, {:capacity, :sessions}} <- session(scope, runtime),
         {:ok, run, _question} <- question_run(first, "Hold the only model slot"),
         {:error, {:capacity, :model}} <-
           OhMyJido.prompt(
             second,
             "Refuse excess work",
             script("Refuse excess work", [answer("No")])
           ),
         :ok <- OhMyJido.cancel(first, run),
         {:error, %{status: :cancelled}} <- OhMyJido.await(first, run, timeout: @wait_timeout) do
      answer_run(second, "Use the released slot", "Capacity released.")
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/models_test.exs:6,75 and session.ex:150-153.
  defp model_role(scope) do
    roles = %{coding: :capable, planning: :fast}
    {runtime, _pid} = runtime(scope, "Roles", model_roles: roles)

    with {:ok, session} <- session(scope, runtime),
         {:ok, selected} <- OhMyJido.Models.select([role: :planning], %{model_roles: roles}),
         :ok <- answer_run(session, "Plan without a provider", "Plan selected.", role: :planning),
         {:ok, %{payload: %{role: :planning, model: model}}} <- wait_event(session, :run_started) do
      check(model == Jido.AI.model_label(selected.model), "Run did not use the planning model")
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/ast/structural_action_test.exs:103-135.
  defp structural(scope) do
    {runtime, _pid} = runtime(scope)
    source = "# IO.inspect(value) is not a call\nvalue = 42\nIO.inspect(value)\n"

    with {:ok, session} <- session(scope, runtime, permissions: [:read, :ast], tools: [Tools.AST]),
         {:ok, %{workspace: root}} <- OhMyJido.inspect_session(session),
         :ok <- File.write(Path.join(root, "syntax.ex"), source),
         {:ok, %{count: 1, truncated: false, matches: [match], snapshot: snapshot}} <-
           OhMyJido.execute_tool(session, "ast", %{
             operation: "search",
             path: "syntax.ex",
             pattern: "IO.inspect(value)"
           }) do
      check(
        match.source == "IO.inspect(value)" and match.range.start.line == 3 and
          snapshot == OhMyJido.Files.snapshot(source),
        "Structural search did not distinguish a call from comment text"
      )
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/host_extensions_test.exs:255-277, using the execution-free local adapter.
  defp artifact(scope) do
    {runtime, _pid} = runtime(scope)
    png = Base.decode64!(@png)
    adapters = %{artifact: {OhMyJido.Extensions.Artifact.Local, []}}

    with {:ok, session} <-
           session(scope, runtime,
             permissions: [:read, :artifact],
             tools: [Tools.Artifact],
             adapters: adapters
           ),
         {:ok, %{workspace: root}} <- OhMyJido.inspect_session(session),
         :ok <- File.write(Path.join(root, "one.png"), png),
         {:ok, %{width: 1, height: 1, media_type: "image/png", path: "one.png", sha256: hash}} <-
           OhMyJido.execute_tool(session, "artifact", %{
             operation: "inspect",
             path: "one.png",
             kind: "image"
           }) do
      check(
        hash == OhMyJido.Files.snapshot(png),
        "Artifact identity differs from the workspace PNG"
      )
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/observer_test.exs:7,75,164,186. No distributed target is configured.
  defp observer(scope) do
    {runtime, _pid} = runtime(scope)
    adapters = %{observer: {OhMyJido.Intelligence.Observer, [target: :local]}}

    with {:ok, session} <-
           session(scope, runtime,
             permissions: [:observe],
             tools: [Tools.Observer],
             adapters: adapters
           ),
         {:ok, %{system: system}} <-
           OhMyJido.execute_tool(session, "observer", %{operation: "overview"}),
         {:ok, %{entries: applications}} <-
           OhMyJido.execute_tool(session, "observer", %{operation: "applications", limit: 200}),
         {:ok, %{entries: processes, count: count}} <-
           OhMyJido.execute_tool(session, "observer", %{operation: "processes", limit: 2}) do
      check(
        system.process_limit == :erlang.system_info(:process_limit) and count <= 2 and count > 0 and
          Enum.any?(applications, &(&1.name == "elixir")) and
          Enum.all?(processes, &safe_process?/1),
        "Observer metadata was missing, unbounded or exposed private process fields"
      )
    else
      other -> mismatch(other)
    end
  end

  defp safe_process?(process) do
    is_binary(process.pid) and not Map.has_key?(process, :dictionary) and
      not Map.has_key?(process, :messages) and not Map.has_key?(process, :state)
  end

  defp parent(scope) do
    {runtime, _pid} = runtime(scope)

    session(scope, runtime,
      permissions: [:read, :ask, :delegate],
      tools: [Tools.Read, Tools.Question]
    )
  end

  defp child(parent, task, tag, turns) do
    OhMyJido.delegate(parent, task, script(task, turns) ++ [tag: tag, permissions: [:read, :ask]])
  end

  defp child_file(parent) do
    with {:ok, %{workspace: root}} <- OhMyJido.inspect_session(parent) do
      File.write(Path.join(root, "facts.txt"), "Shared read-only fact.\n")
    end
  end

  # Mirrors test/delegation_test.exs:44-98,713-718 (explicit per-child script options).
  defp subagent(scope) do
    turns = [call("read", %{path: "facts.txt"}), answer("Child inspected the fact.")]

    with {:ok, parent} <- parent(scope),
         :ok <- child_file(parent),
         {:ok, child} <- child(parent, "Inspect the child fact", "reader", turns),
         {:ok, %{status: :completed, answer: "Child inspected the fact.", tools: tools}} <-
           OhMyJido.await_child(parent, child.tag, timeout: @wait_timeout),
         {:ok, %{permissions: permissions}} <- OhMyJido.inspect_session(child.session) do
      check(
        Enum.any?(tools, &(&1.name == "read" and &1.status == :completed)) and
          Enum.sort(permissions) == [:ask, :read],
        "Child did not execute its real read with narrowed permissions"
      )
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/delegation_test.exs:272-351; questions form an OTP-only overlap barrier.
  defp parallel_children(scope) do
    with {:ok, parent} <- parent(scope),
         :ok <- child_file(parent),
         {:ok, first} <- waiting_child(parent, "First exploration", "first"),
         {:ok, first_question} <- wait_event(first.session, :approval_requested),
         {:ok, second} <- waiting_child(parent, "Second exploration", "second"),
         {:ok, second_question} <- wait_event(second.session, :approval_requested),
         {:ok, %{status: :running}} <- OhMyJido.inspect_session(first.session),
         {:ok, %{status: :running}} <- OhMyJido.inspect_session(second.session),
         :ok <- OhMyJido.answer(first.session, first_question.payload.id, "continue"),
         :ok <- OhMyJido.answer(second.session, second_question.payload.id, "continue"),
         {:ok, %{status: :completed, answer: "Exploration completed."}} <-
           OhMyJido.await_child(parent, first.tag, timeout: @wait_timeout),
         {:ok, %{status: :completed, answer: "Exploration completed."}} <-
           OhMyJido.await_child(parent, second.tag, timeout: @wait_timeout) do
      check(first.session != second.session, "Parallel tasks shared a child identity")
    else
      other -> mismatch(other)
    end
  end

  defp waiting_child(parent, task, tag) do
    turns = [
      call("read", %{path: "facts.txt"}),
      call("question", %{question: "Release this exploration?"}),
      answer("Exploration completed.")
    ]

    child(parent, task, tag, turns)
  end

  # Mirrors test/delegation_test.exs:425-428,458-555.
  defp child_control(scope) do
    turns = [call("question", %{question: "Wait for parent control?"}), answer("Not reached.")]

    with {:ok, parent} <- parent(scope),
         {:ok, child} <- child(parent, "Wait for the parent", "controlled", turns),
         {:ok, _event} <- wait_event(child.session, :approval_requested),
         :ok <- OhMyJido.steer_child(parent, child.tag, "Do not start another effect."),
         :ok <- OhMyJido.cancel_child(parent, child.tag),
         {:error, %{status: :cancelled}} <-
           OhMyJido.await_child(parent, child.tag, timeout: @wait_timeout),
         {:ok, %{status: :idle}} <- OhMyJido.inspect_session(parent) do
      answer_run(parent, "Continue the parent", "Parent remains usable.")
    else
      other -> mismatch(other)
    end
  end

  # Mirrors runtime_test.exs:45 and session.ex:348-359.
  defp checkpoints(scope) do
    {runtime, _pid} = runtime(scope)

    with {:ok, session} <- session(scope, runtime, permissions: [:ask], tools: [Tools.Question]),
         :ok <- OhMyJido.checkpoint(session),
         {:ok, run, _question} <- question_run(session, "Reject an active checkpoint"),
         {:error, :run_active} <- OhMyJido.checkpoint(session),
         :ok <- OhMyJido.cancel(session, run),
         {:error, %{status: :cancelled}} <- OhMyJido.await(session, run, timeout: @wait_timeout) do
      OhMyJido.checkpoint(session)
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/experiment_test.exs:47 and memory_workflow_test.exs:109-115.
  defp memory(scope) do
    {runtime, _pid} = runtime(scope)
    facts = %{memory: %{"browser-fact" => "No external processes"}, constraints: ["Keep the API"]}

    with {:ok, session} <- session(scope, runtime),
         :ok <- OhMyJido.retain(session, facts),
         :ok <- OhMyJido.stop_session(session),
         {:ok, ^session} <- OhMyJido.resume_session(runtime, session.id),
         {:ok, %{retained: retained}} <- OhMyJido.inspect_session(session) do
      check(
        retained["retained"]["memory"] == facts.memory and
          retained["retained"]["constraints"] == facts.constraints,
        "Explicit task facts did not survive stop and resume"
      )
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/skill_test.exs:91-113; no filesystem skill roots are supplied.
  defp skills(scope) do
    {runtime, _pid} = runtime(scope)

    spec = %Jido.AI.Skill.Spec{
      name: "browser-policy",
      description: "Browser probe guidance",
      source: nil,
      body_ref: {:inline, "Preserve operator approvals."},
      allowed_tools: ["read"]
    }

    metadata = %{skills: [%{skill: spec, approved: true}]}
    skill_session(scope, runtime, metadata)
  end

  defp skill_session(scope, runtime, metadata) do
    with {:ok, session} <-
           session(scope, runtime,
             permissions: [:skills],
             tools: [Tools.Skill],
             metadata: metadata
           ),
         {:ok, %{skills: [%{name: "browser-policy"}], authority: :guidance_only}} <-
           OhMyJido.execute_tool(session, "skill", %{operation: "discover"}),
         {:ok, %{instructions: "Preserve operator approvals.", authority: :guidance_only}} <-
           OhMyJido.execute_tool(session, "skill", %{operation: "load", name: "browser-policy"}),
         {:ok, %{permissions: [:skills]}} <- OhMyJido.inspect_session(session) do
      :ok
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/context_constructor_test.exs:131-148 and session.ex:521-550.
  defp custom_tool(scope) do
    {runtime, _pid} = runtime(scope)

    with {:ok, session} <- session(scope, runtime, permissions: [:custom]),
         :ok <- OhMyJido.register_tool(session, Echo),
         {:ok, %{echo: "real action"}} <-
           OhMyJido.execute_tool(session, "browser_probe_echo", %{value: "real action"}),
         :ok <- OhMyJido.unregister_tool(session, "browser_probe_echo"),
         {:error, {:unknown_tool, "browser_probe_echo"}} <-
           OhMyJido.execute_tool(session, "browser_probe_echo", %{value: "must not run"}) do
      :ok
    else
      other -> mismatch(other)
    end
  end

  # Mirrors test/experiment_test.exs:102-142, substituting bounded reads for Shell.
  defp experiments(scope) do
    {runtime, _pid} = runtime(scope, "Experiments", max_experiment_trials: 2)
    trials = List.duplicate(%{tool: "read", params: %{path: "trial.txt"}}, 2)

    with {:ok, session} <-
           session(scope, runtime,
             permissions: [:read, :experiments],
             tools: [Tools.Read, Tools.Experiment]
           ),
         {:ok, %{workspace: root}} <- OhMyJido.inspect_session(session),
         :ok <- File.write(Path.join(root, "trial.txt"), "Measured input"),
         {:ok, %{status: :completed, results: results} = record} <-
           OhMyJido.execute_tool(session, "experiment", %{trials: trials}),
         {:error, %{details: %{reason: :invalid_or_excessive_trials}}} <-
           OhMyJido.execute_tool(session, "experiment", %{trials: trials ++ trials}),
         {:ok, %{retained: retained}} <- OhMyJido.inspect_session(session) do
      check(
        match?([_, _], results) and Enum.all?(results, &measured_read?/1) and
          retained["retained"]["memory"]["experiment:" <> record.id] ==
            Jason.decode!(Jason.encode!(record)),
        "Experiment trials or retained measured results did not match"
      )
    else
      other -> mismatch(other)
    end
  end

  defp measured_read?(trial) do
    trial.status == :completed and trial.duration_us >= 0 and
      trial.receipt.name == "read" and trial.receipt.status == :completed and
      match?([:ok, %{content: "Measured input"}], trial.result)
  end

  # Ordered native events mirror runtime_test.exs:13-42; telemetry is session.ex:1498.
  defp observability(scope) do
    {runtime, _pid} = runtime(scope)

    with {:ok, session} <- session(scope, runtime),
         :ok <-
           :telemetry.attach(
             {__MODULE__, scope.token},
             [:oh_my_jido, :event],
             &__MODULE__.handle_telemetry/4,
             {self(), session.id, scope.token}
           ) do
      observe_run(scope.token, session)
    else
      other -> mismatch(other)
    end
  end

  defp observe_run(token, session) do
    with :ok <- answer_run(session, "Emit real telemetry", "Observed."),
         :ok <- telemetry_kind(token, :run_started),
         do: telemetry_kind(token, :run_completed)
  after
    :telemetry.detach({__MODULE__, token})
  end

  defp telemetry_kind(token, kind) do
    receive do
      {:probe_telemetry, ^token, ^kind} -> :ok
    after
      @wait_timeout -> {:error, "Missing #{kind} telemetry"}
    end
  end
end
