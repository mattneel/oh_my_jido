defmodule OhMyJido do
  @moduledoc """
  Embeds a coding agent in your Elixir application.

  Oh-My-Jido uses Jido for agent supervision, Jido.AI for the model/tool loop,
  and ReqLLM for model providers. Your application chooses the workspace,
  tools, permissions, model, credentials, and approval policy.

  Add a named runtime to your supervision tree, then open a session:

      children = [{OhMyJido, name: MyApp.Coding}]

      {:ok, session} =
        OhMyJido.start_session(MyApp.Coding,
          workspace: "/path/to/project",
          permissions: [:read]
        )

      {:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})

  Starting a runtime starts no session or model request. The example above
  needs no model credentials. To run an AI task, configure a credentials
  resolver and select an active model and account, then use `prompt/3` and
  `await/3`. See the Getting started and Models and accounts guides.

  Session references are durable identities, not worker PIDs. Subscribe with
  `subscribe/3` to receive `{:oh_my_jido, %OhMyJido.Event{}}` messages.
  Cancellation requests a stop; it never rolls back earlier effects.
  `await/3` reports the terminal run status, while `inspect_session/1` lets
  trusted application code inspect uncertain effects before reconciliation.
  """

  use Boundary,
    deps: [],
    exports: [
      Runtime,
      SessionRef,
      Event,
      Context,
      Host,
      Host.Local,
      Tool,
      Session,
      Redact,
      Models,
      Models.Subscription,
      Prompt,
      ContextPolicy,
      Auth,
      Auth.Broker,
      Auth.Vault,
      Auth.FileStore,
      Auth.Error,
      Auth.OpenAI,
      Eval,
      Eval.Backend,
      Eval.API,
      Tools,
      Plugin,
      Plugin.ContextProvider,
      Workspace,
      Files,
      Search,
      Git,
      Process,
      Process.Handle,
      Intelligence.AST,
      Intelligence.LSP,
      Intelligence.DAP,
      Intelligence.Observer,
      Intelligence.Stdio,
      Intelligence.TextEdits,
      Extensions,
      Extensions.Browser,
      Extensions.Artifact,
      Extensions.Artifact.Local,
      Extensions.MCP,
      Extensions.Tidewave,
      Extensions.Research,
      Extensions.Review
    ]

  alias OhMyJido.{Runtime, Session, SessionRef}

  @doc """
  Supervises a named coding runtime directly as `{OhMyJido, name: MyApp.Coding}`.

  This starts no session, model request or optional language service. Storage,
  credential resolution and permissions remain explicit host choices.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: Runtime

  @doc "Starts a named runtime; prefer its child specification in your application supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts), to: Runtime

  @doc "Opens a session in an existing workspace; permissions default to an empty list."
  @spec start_session(atom(), keyword()) :: {:ok, SessionRef.t()} | {:error, term()}
  defdelegate start_session(runtime, opts), to: Runtime

  @doc "Restores conversation and checkpoints, without replaying interrupted effects."
  @spec resume_session(atom(), String.t()) :: {:ok, SessionRef.t()} | {:error, term()}
  defdelegate resume_session(runtime, id), to: Runtime

  @doc "Lists currently supervised session identities."
  @spec list_sessions(atom()) :: [SessionRef.t()]
  defdelegate list_sessions(runtime), to: Runtime

  @doc "Submits a task and returns `{:ok, run_id}`; admission does not mean the model request succeeded."
  @spec prompt(SessionRef.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prompt(session, task, opts \\ []), do: Session.call(session, {:prompt, task, opts})

  @doc "Waits for a run result; a caller timeout does not cancel the run."
  @spec await(SessionRef.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(session, run, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    Session.call(session, {:await, run, timeout}, timeout + 1_000)
  end

  @doc "Subscribes a PID to future ordered events; subscribers exceeding their mailbox bound are detached."
  @spec subscribe(SessionRef.t(), pid(), keyword()) :: :ok | {:error, term()}
  def subscribe(session, pid, opts \\ []), do: Session.call(session, {:subscribe, pid, opts})

  @doc "Reads the bounded event buffer after a sequence number."
  @spec events(SessionRef.t(), keyword()) :: [OhMyJido.Event.t()] | {:error, term()}
  def events(session, opts \\ []),
    do: Session.call(session, {:events, Keyword.get(opts, :after, 0)})

  @doc "Queues steering for the active native ReAct request."
  @spec steer(SessionRef.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def steer(session, run, text), do: Session.call(session, {:steer, run, text})

  @doc "Requests cancellation and prevents new effects for this run."
  @spec cancel(SessionRef.t(), String.t()) :: :ok | {:error, term()}
  def cancel(session, run), do: Session.call(session, {:cancel, run, :user_cancelled})

  @doc "Cancels the active run as suspended and blocks new prompts until `resume/1`."
  @spec suspend(SessionRef.t(), String.t()) :: :ok | {:error, term()}
  def suspend(session, run), do: Session.call(session, {:cancel, run, :suspended})

  @doc "Allows new prompts after suspension; does not continue or replay the cancelled run."
  @spec resume(SessionRef.t()) :: :ok | {:error, term()}
  def resume(session), do: Session.call(session, :resume)

  @doc """
  Returns redacted, host-only session state.

  The `agent_pid` field is an intentional transient native diagnostic handle.
  Do not serialize it or expose this snapshot as public UI/telemetry data.
  """
  @spec inspect_session(SessionRef.t()) :: {:ok, map()} | {:error, term()}
  def inspect_session(session), do: Session.call(session, :inspect)

  @doc "Writes an explicit safe checkpoint; active runs are rejected."
  @spec checkpoint(SessionRef.t()) :: :ok | {:error, term()}
  def checkpoint(session), do: Session.call(session, :checkpoint)

  @doc """
  Records explicit operator reconciliation of a restored interrupted execution.

  This is a trusted-host operation, not a model tool or a replacement for
  `stop_session/1`. The operator must first independently stop/reconcile the
  original owned workers, OS groups and external resources. Actor or caller
  death alone is not that evidence.

  The current owner must be idle or suspended with no active run, stop,
  registered resources or cleanup work. The run and complete expected pending
  effect-ID set must match the original restore-time interrupted eligibility;
  later work, stale sets and partial sets are rejected without mutation.

  The durable `execution_settlement` is explicitly `source: :operator` and
  `native_stop_confirmed: false`. It preserves the uncertain outcome, existing
  history and missing result/`completed_at`; no native SDK closure or successful
  effect is invented. Late results cannot overwrite this boundary. Reconciliation
  makes no model call and does not replay the interrupted continuation.

  Do not expose this acknowledgement through browser, model-tool or MCP inputs.
  """
  @spec reconcile_interrupted(
          SessionRef.t(),
          String.t(),
          [String.t()],
          :orphan_resources_reconciled
        ) :: :ok | {:error, term()}
  def reconcile_interrupted(session, run_id, expected_effect_ids, :orphan_resources_reconciled)
      when is_binary(run_id) and is_list(expected_effect_ids) do
    Session.call(session, {:reconcile_interrupted, run_id, expected_effect_ids})
  end

  def reconcile_interrupted(_session, _run_id, _expected_effect_ids, _acknowledgement),
    do: {:error, :invalid_reconciliation}

  @doc """
  Seals admission and stops a session only after native effects and resources settle.

  `:ok` confirms cleanup before the exact session child is terminated; it does
  not roll back earlier writes. Settlement waits up to five seconds. An error
  with `reason: :cleanup_uncertain` leaves the session supervised and sealed
  while outstanding receipts can still arrive. A process exit alone is not a
  cleanup receipt.
  """
  @spec stop_session(SessionRef.t()) :: :ok | {:error, term()}
  def stop_session(session) do
    with pid when is_pid(pid) <- GenServer.whereis(Runtime.via(session)),
         :ok <- Session.call(pid, :prepare_stop) do
      DynamicSupervisor.terminate_child(Runtime.sessions(session.runtime), pid)
    else
      nil -> {:error, :session_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc "Answers one structured host approval or clarification request."
  @spec answer(SessionRef.t(), String.t(), term()) :: :ok | {:error, term()}
  def answer(session, question_id, answer),
    do: Session.call(session, {:answer, question_id, answer})

  @doc "Retains a goal, constraints, file facts, memory, or unresolved work; supplied unresolved work replaces its prior list."
  @spec retain(SessionRef.t(), map()) :: :ok | {:error, term()}
  def retain(session, facts), do: Session.call(session, {:retain, facts})

  @doc "Replaces the task plan without removing existing items, renaming them, or reopening completed work."
  @spec plan(SessionRef.t(), [map()]) :: :ok | {:error, term()}
  def plan(session, items), do: Session.call(session, {:plan, items})

  @doc "Completes an all-done, nonempty plan using `%{effect_ids: ids}` from successful shell checks."
  @spec complete_goal(SessionRef.t(), map()) :: :ok | {:error, term()}
  def complete_goal(session, evidence), do: Session.call(session, {:goal_complete, evidence})

  @doc "Registers an application-authored Jido Action while the session is idle."
  @spec register_tool(SessionRef.t(), module()) :: :ok | {:error, term()}
  def register_tool(session, action), do: Session.call(session, {:register_tool, action})

  @doc "Removes an exact tool name from future model turns while the session is idle."
  @spec unregister_tool(SessionRef.t(), String.t()) :: :ok | {:error, term()}
  def unregister_tool(session, name), do: Session.call(session, {:unregister_tool, name})

  @doc """
  Runs a registered tool with session permissions, authorization, and effect recording.

  Options are `:timeout` and an optional application-supplied `:effect_id`.
  Recorded IDs cannot be reused. Effects are never automatically retried.
  A `:effect_recording_failed` error can contain an observed result even though
  durable recording failed; reconcile it instead of running the effect again.
  """
  @spec execute_tool(SessionRef.t(), String.t(), map(), keyword()) :: term()
  def execute_tool(session, name, params, opts \\ []) do
    with {:ok, context} <- Session.call(session, :context) do
      OhMyJido.Tool.execute(context, name, params, opts)
    end
  end

  @doc "Delegates a distinct task with narrowed privileges and isolated writes."
  @spec delegate(SessionRef.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delegate(session, task, opts \\ []), do: OhMyJido.Delegation.start(session, task, opts)

  @doc "Collects a child's structured result without changing the parent's run."
  @spec await_child(SessionRef.t(), String.t(), keyword()) :: term()
  def await_child(session, tag, opts \\ []), do: OhMyJido.Delegation.await(session, tag, opts)

  @doc "Steers a tracked child through its native ReAct control path."
  @spec steer_child(SessionRef.t(), String.t(), String.t()) :: term()
  def steer_child(session, tag, text), do: OhMyJido.Delegation.steer(session, tag, text)

  @doc "Cancels a tracked child without stopping the parent session."
  @spec cancel_child(SessionRef.t(), String.t()) :: term()
  def cancel_child(session, tag), do: OhMyJido.Delegation.cancel(session, tag)

  @doc "Runs bounded tool trials once and retains their measured results; inspect the returned record's status."
  @spec experiment(SessionRef.t(), [map()], keyword()) :: term()
  def experiment(session, trials, opts \\ []), do: OhMyJido.Experiment.run(session, trials, opts)
end
