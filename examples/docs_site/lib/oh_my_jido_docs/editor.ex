defmodule OhMyJidoDocs.Editor do
  @moduledoc """
  Private, source-first editorial sessions backed by SQLite and native OhMyJido.

  Supervise `OhMyJidoDocs.Coding` with `Editor.Host`, durable native storage,
  `max_active: 1`, `max_sessions: 8`, and no test scripts in production. Place
  `child_specs/0` after Repo, Phoenix.PubSub and that native runtime. The observer
  persists native events independently of browser subscribers; its only timer
  reconciles native state and checkpoints, never runs a model loop.

  `start_run/2` accepts task/mode only and returns a queued durable row while a
  supervised task creates the source snapshot. Its options are host-only native
  ReAct test options, gated by the runtime's explicit `allow_test_scripts` flag.
  The web layer must never forward arbitrary params as those options.
  Queued cancellation retains its workspace creator until it finishes, then
  discards that exact allocation in a supervised task. Durable cleanup remains
  pending, and counts against admission, until deletion actually succeeds.
  Observer recovery joins surviving old tasks before attempting their cleanup.
  A bounded host task holds the protected workspace lease for the entire native
  writer lifetime, not merely a prompt RPC. SQLite records its pending claim
  before native startup. Publication must call `source_write_settled/1` under
  its own `Workspaces.with_workspace_lease/2`, including the final digest/CAS.
  Holder/observer death never clears that durable fence. A native actor or
  Session going DOWN is not an execution/resource cleanup receipt. Confirmed
  native stop settles the fence; an absent process with no graceful-stop receipt
  stays blocked until a trusted operator explicitly reconciles orphan resources.
  Operator reconciliation retains outcome uncertainty, restores only a temporary
  owner, imports the explicit operator execution settlement, and strongly stops
  that new owner before releasing the fence. It never upgrades the lost old
  owner's shutdown to a confirmed native receipt.
  SQLite records private operator provenance for the exact claim before temporary
  startup. Recovery resolves interrupted native identity from the checkpoint,
  not a possibly unpersisted prompt response, and retains that provenance across
  Observer loss until exact-claim settlement.

  Resume restores native context without replaying work. A subsequent explicit
  `steer_run/2` on a ready session starts a new native turn; on an active session
  it queues native steering. `steer_run/3` accepts the same host-only, explicitly
  gated native test options as `start_run/2`, only for a new ready-session turn.
  Neither recovery nor resumption calls a provider.
  A resumed row becomes ready only after its actual checkpoint and strong stop
  succeed; failed settlement returns its real error and retains the fence.
  The authenticated web boundary owns operator identity and access control; this
  module is a trusted host API and must not be exposed through public routes.
  """

  import Ecto.Query

  alias OhMyJidoDocs.Editor.{Observer, Run, RunEvent, Writers}
  alias OhMyJidoDocs.Repo

  @event_limit 256

  def child_specs, do: [{__MODULE__.Supervisor, []}]

  def list_runs do
    Repo.all(from r in Run, order_by: [desc: r.inserted_at, desc: r.id], limit: 100)
  end

  def get_run!(id), do: Repo.get!(Run, id)

  def start_run(attrs, opts \\ []), do: Observer.call({:start_run, attrs, opts})

  def subscribe(id), do: Phoenix.PubSub.subscribe(OhMyJidoDocs.PubSub, topic(id))

  def snapshot(id) do
    run = get_run!(id)

    events =
      Repo.all(
        from e in RunEvent, where: e.run_id == ^id, order_by: [desc: e.seq], limit: @event_limit
      )
      |> Enum.reverse()

    questions =
      run.pending_questions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, question} -> %{id: id, question: question} end)

    %{run: run, events: events, session: run.session_snapshot, pending_questions: questions}
  end

  def steer_run(id, text, opts \\ []), do: Observer.call({:steer, id, text, opts})
  def cancel_run(id), do: Observer.call({:cancel, id})
  def suspend_run(id), do: Observer.call({:suspend, id})
  def resume_run(id), do: Observer.call({:resume, id})
  def answer(id, question_id, value), do: Observer.call({:answer, id, question_id, value})

  @doc """
  Checks durable source-writer settlement under the caller's workspace lease.
  Database unavailability fails closed; unmanaged source workspaces are allowed.
  """
  def source_write_settled(workspace), do: Writers.source_write_settled(workspace)

  @doc """
  Explicitly acknowledges externally reconciled orphan resources after an
  unconfirmed native shutdown. This trusted-host-only operation requires the
  exact durable claim token and acknowledgement atom, and refuses a live original
  native owner. Inspect and stop any actual owned OS groups before acknowledging;
  a stale claim cannot clear a later execution's fence. Operator provenance is
  durable before restoration; retries may join the same temporary owner without
  promoting its shutdown proof to the lost owner's receipt.
  It temporarily restores the native checkpoint without a provider call or
  replay, preserves uncertain outcomes without synthetic results/completion
  times, and strongly stops that new owner. Durable evidence distinguishes
  `operator_reconciled: true`, `native_stop_confirmed: false`, and
  `restored_owner_stop_confirmed: true`.
  """
  def reconcile_writer(id, expected_claim, :orphan_resources_reconciled),
    do: Observer.call({:reconcile_writer, id, expected_claim})

  @doc false
  def topic(id), do: "docs-run:#{id}"
end
