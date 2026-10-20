defmodule OhMyJido do
  @moduledoc """
  Embeddable, host-controlled coding agents on Jido and OTP.

  Supervise `{OhMyJido.Runtime, name: MyApp.Coding, host: MyApp.Host}` in the
  host application. Start a session with an explicit workspace and grants,
  subscribe to typed events, then submit a task. Model calls use Jido.AI and
  ReqLLM; credentials come from the host, never ambient credential files.

  Session references are durable identities. Cancellation is requested, not a
  claim that previous effects were rolled back. `await/3` reports the eventual
  terminal status, and `inspect_session/1` exposes uncertain effect records.
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
      Plugin.AgentExtension,
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

  @doc "Starts a capability-scoped session under a named host runtime."
  @spec start_session(atom(), keyword()) :: {:ok, SessionRef.t()} | {:error, term()}
  defdelegate start_session(runtime, opts), to: Runtime

  @doc "Restores conversation and checkpoints, without replaying interrupted effects."
  @spec resume_session(atom(), String.t()) :: {:ok, SessionRef.t()} | {:error, term()}
  defdelegate resume_session(runtime, id), to: Runtime

  @doc "Lists currently supervised session identities."
  @spec list_sessions(atom()) :: [SessionRef.t()]
  defdelegate list_sessions(runtime), to: Runtime

  @doc "Submits a task and returns a durable run ID."
  @spec prompt(SessionRef.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prompt(session, task, opts \\ []), do: Session.call(session, {:prompt, task, opts})

  @doc "Waits for a run result; a caller timeout does not cancel the run."
  @spec await(SessionRef.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await(session, run, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    Session.call(session, {:await, run, timeout}, timeout + 1_000)
  end

  @doc "Consumes redacted ordered events; slow subscribers are detached at their bound."
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

  @doc "Suspends a run; resumption never blindly retries its interrupted effects."
  @spec suspend(SessionRef.t(), String.t()) :: :ok | {:error, term()}
  def suspend(session, run), do: Session.call(session, {:cancel, run, :suspended})

  @doc "Unblocks a suspended session for a new, context-aware task."
  @spec resume(SessionRef.t()) :: :ok | {:error, term()}
  def resume(session), do: Session.call(session, :resume)

  @doc """
  Returns redacted, host-only session state.

  The `agent_pid` field is an intentional transient native diagnostic handle.
  It can be `nil` when a sealed session has retired its native actor but still
  retains unresolved effect or resource receipts.
  Do not serialize it or expose this snapshot as public UI/telemetry data.
  """
  @spec inspect_session(SessionRef.t()) :: {:ok, map()} | {:error, term()}
  def inspect_session(session), do: Session.call(session, :inspect)

  @doc "Writes an explicit safe checkpoint; active runs are rejected."
  @spec checkpoint(SessionRef.t()) :: :ok | {:error, term()}
  def checkpoint(session), do: Session.call(session, :checkpoint)

  @doc """
  Seals admission and stops a session only after native effects and resources settle.

  `:ok` confirms cleanup before the exact session child is terminated; it does
  not roll back earlier writes. Settlement waits up to five seconds. An error
  with `reason: :cleanup_uncertain` leaves the session supervised and sealed
  while outstanding receipts can still arrive. Its exact idle native actor is
  retired independently, releasing its parent relationship without inventing
  execution/effect/resource closure. A process exit alone is not a cleanup receipt.
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

  @doc "Retains goals, constraints, file facts, memory, and unresolved work durably."
  @spec retain(SessionRef.t(), map()) :: :ok | {:error, term()}
  def retain(session, facts), do: Session.call(session, {:retain, facts})

  @doc "Updates the explicit task plan with validated transitions."
  @spec plan(SessionRef.t(), [map()]) :: :ok | {:error, term()}
  def plan(session, items), do: Session.call(session, {:plan, items})

  @doc "Completes a goal only when all plan items and verification evidence permit it."
  @spec complete_goal(SessionRef.t(), map()) :: :ok | {:error, term()}
  def complete_goal(session, evidence), do: Session.call(session, {:goal_complete, evidence})

  @doc "Registers a host-authored Jido Action on this session."
  @spec register_tool(SessionRef.t(), module()) :: :ok | {:error, term()}
  def register_tool(session, action), do: Session.call(session, {:register_tool, action})

  @doc "Removes a tool from subsequent model turns."
  @spec unregister_tool(SessionRef.t(), String.t()) :: :ok | {:error, term()}
  def unregister_tool(session, name), do: Session.call(session, {:unregister_tool, name})

  @doc "Executes an explicitly registered tool with the session's authority."
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

  @doc "Runs bounded, approved experiments and retains results and artifacts."
  @spec experiment(SessionRef.t(), [map()], keyword()) :: term()
  def experiment(session, trials, opts \\ []), do: OhMyJido.Experiment.run(session, trials, opts)
end
