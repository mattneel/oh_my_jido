defmodule OhMyJidoDocsWeb.StudioLive do
  use OhMyJidoDocsWeb, :live_view

  alias OhMyJidoDocs.{Candidates, Editor}
  alias OhMyJidoDocsWeb.PreviewCapability

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Studio",
       run: nil,
       session_summary: nil,
       pending_questions: [],
       selected_candidate: nil,
       review_digest: nil,
       selected_candidate_id: nil,
       preview_src: nil,
       preview_notice: nil,
       action_label: nil,
       run_count: 0,
       event_count: 0,
       candidate_count: 0,
       subscribed_run: nil,
       task_form: to_form(%{"task" => "", "mode" => "docs"}, as: :run),
       steer_form: to_form(%{"text" => ""}, as: :steer)
     )
     |> stream(:runs, [])
     |> stream(:events, [])
     |> stream(:candidates, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params do
      %{"id" => id} ->
        socket = subscribe(socket, id)

        {:noreply,
         socket
         |> assign(:selected_candidate_id, params["candidate_id"])
         |> assign(:review_digest, nil)
         |> load_run(id)}

      _ ->
        {:noreply,
         socket
         |> assign(
           run: nil,
           selected_candidate: nil,
           review_digest: nil,
           preview_src: nil,
           preview_notice: nil
         )
         |> load_runs()}
    end
  end

  @impl true
  def handle_info({:docs_run_updated, id}, %{assigns: %{run: %{id: id}}} = socket) do
    {:noreply, load_run(socket, id)}
  end

  def handle_info({:docs_run_updated, _id}, socket), do: {:noreply, load_runs(socket)}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("start_run", %{"run" => params}, socket) when is_map(params) do
    attrs = Map.take(params, ["task", "mode"])

    if is_binary(attrs["task"]) and String.trim(attrs["task"]) != "" and
         attrs["mode"] in ["docs", "coding"] do
      {:noreply,
       begin_action(socket, :start_run, "Starting workspace", fn -> Editor.start_run(attrs) end)}
    else
      {:noreply,
       put_flash(socket, :error, "Describe a source change and choose an editing mode.")}
    end
  end

  def handle_event("steer", %{"steer" => %{"text" => text}}, socket) do
    with %{id: id} <- socket.assigns.run,
         true <- is_binary(text) and String.trim(text) != "" do
      {:noreply,
       begin_action(socket, :steer, "Sending direction", fn -> Editor.steer_run(id, text) end)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Enter the next instruction first.")}
    end
  end

  def handle_event(action, _params, socket) when action in ["cancel", "suspend", "resume"] do
    if run = socket.assigns.run do
      callback =
        case action do
          "cancel" -> fn -> Editor.cancel_run(run.id) end
          "suspend" -> fn -> Editor.suspend_run(run.id) end
          "resume" -> fn -> Editor.resume_run(run.id) end
        end

      {:noreply, begin_action(socket, action, "Requesting #{action}", callback)}
    else
      {:noreply, put_flash(socket, :error, "Open a run before sending a control.")}
    end
  end

  def handle_event("answer", %{"question_id" => id, "answer" => answer}, socket) do
    case pending_question(socket, id) do
      %{question: question} when is_binary(answer) ->
        if field(question, "kind") != "process" and String.trim(answer) != "" do
          run_id = socket.assigns.run.id

          {:noreply,
           begin_action(socket, :answer, "Sending answer", fn ->
             Editor.answer(run_id, id, answer)
           end)}
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Use the explicit approval buttons for process effects, or enter an answer."
           )}
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, "That question is no longer pending. Refresh the run.")}
    end
  end

  def handle_event(action, %{"question_id" => id}, socket)
      when action in ["approve_effect", "deny_effect"] do
    case pending_question(socket, id) do
      %{question: question} ->
        record_process_decision(action, id, question, socket)

      _ ->
        {:noreply,
         put_flash(socket, :error, "That approval is no longer pending. Refresh the run.")}
    end
  end

  def handle_event("prepare_candidate", _params, socket) do
    if run = socket.assigns.run do
      {:noreply,
       begin_action(socket, :prepare_candidate, "Capturing immutable source", fn ->
         Candidates.prepare(run.id)
       end)}
    else
      {:noreply, put_flash(socket, :error, "Open a run before preparing a candidate.")}
    end
  end

  def handle_event(action, _params, socket)
      when action in [
             "check_candidate",
             "cancel_check",
             "start_preview",
             "stop_preview",
             "approve_candidate",
             "publish_candidate",
             "adopt_candidate",
             "deploy_candidate",
             "cancel_deploy"
           ] do
    case {socket.assigns.selected_candidate, socket.assigns.review_digest} do
      {%{id: id}, digest} when is_binary(digest) ->
        # Route selection and the reviewed digest live in server assigns. Browser
        # values cannot replace the candidate, digest, check result, or approval.
        callback = candidate_action(action, id, digest)

        {:noreply, begin_action(socket, action, action_label(action), callback)}

      _ ->
        {:noreply, put_flash(socket, :error, "Select and review a source candidate first.")}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That control is not available in this view.")}
  end

  @impl true
  def handle_async({:host_action, action}, {:ok, result}, socket) do
    socket = assign(socket, :action_label, nil)

    case result do
      {:ok, %{id: id}} when action == :start_run ->
        {:noreply, push_navigate(socket, to: ~p"/studio/runs/#{id}")}

      {:ok, %{id: id}} when action == :prepare_candidate ->
        {:noreply,
         push_patch(socket, to: ~p"/studio/runs/#{socket.assigns.run.id}/candidates/#{id}")}

      {:error, reason} ->
        {:noreply, socket |> refresh() |> put_flash(:error, format_error(reason))}

      :ok ->
        {:noreply, action_finished(socket, action)}

      {:ok, _value} ->
        {:noreply, action_finished(socket, action)}

      _ ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(
           :error,
           "The host did not accept the action. Refresh and inspect the durable event history."
         )}
    end
  end

  def handle_async({:host_action, _action}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:action_label, nil)
     |> refresh()
     |> put_flash(
       :error,
       "The host action did not complete normally. No success is assumed; inspect the run and candidate receipts before retrying."
     )}
  end

  defp begin_action(%{assigns: %{action_label: label}} = socket, _action, _label, _callback)
       when not is_nil(label) do
    put_flash(
      socket,
      :error,
      "A host request is already in progress. Its result will appear here."
    )
  end

  defp begin_action(socket, action, label, callback) do
    socket |> assign(:action_label, label) |> start_async({:host_action, action}, callback)
  end

  defp action_finished(socket, action) do
    socket =
      if action == :steer,
        do: assign(socket, :steer_form, to_form(%{"text" => ""}, as: :steer)),
        else: socket

    socket |> refresh() |> put_flash(:info, action_receipt(action))
  end

  defp refresh(%{assigns: %{run: %{id: id}}} = socket), do: load_run(socket, id)
  defp refresh(socket), do: load_runs(socket)

  defp load_runs(socket) do
    runs = Editor.list_runs()
    socket |> assign(:run_count, length(runs)) |> stream(:runs, runs, reset: true)
  end

  defp load_run(socket, id) do
    snapshot = Editor.snapshot(id)
    candidates = Candidates.list(id)
    selected = Enum.find(candidates, &(&1.id == socket.assigns.selected_candidate_id))
    review_digest = socket.assigns.review_digest || (selected && selected.digest)
    {preview_src, preview_notice} = preview_source(selected, socket.assigns.operator_session)

    socket
    |> assign(
      run: snapshot.run,
      page_title: "Source run · Studio",
      session_summary: snapshot.session,
      pending_questions: snapshot.pending_questions,
      event_count: length(snapshot.events),
      candidate_count: length(candidates),
      selected_candidate: selected,
      review_digest: review_digest,
      preview_src: preview_src,
      preview_notice: preview_notice
    )
    |> stream(:events, snapshot.events, reset: true)
    |> stream(:candidates, candidates, reset: true)
  rescue
    _error in [Ecto.NoResultsError, Ecto.Query.CastError, Ecto.CastError, ArgumentError] ->
      socket
      |> put_flash(:error, "That source run is not available.")
      |> push_navigate(to: ~p"/studio")
  end

  defp preview_source(%{preview_status: "running", id: id}, session) do
    case PreviewCapability.url_for_candidate(id, session) do
      {:ok, src} ->
        {src, nil}

      {:error, _reason} ->
        {nil,
         "The host could not verify this preview's live process and listening socket. Stop it and start a fresh preview."}
    end
  end

  defp preview_source(_candidate, _session), do: {nil, nil}

  defp subscribe(%{assigns: %{subscribed_run: id}} = socket, id), do: socket

  defp subscribe(socket, id) do
    if connected?(socket) do
      if previous = socket.assigns.subscribed_run do
        Phoenix.PubSub.unsubscribe(OhMyJidoDocs.PubSub, "docs-run:" <> previous)
      end

      Editor.subscribe(id)
    end

    assign(socket, :subscribed_run, id)
  end

  defp pending_question(socket, id) do
    Enum.find(socket.assigns.pending_questions, &(&1.id == id))
  end

  defp field(value, key, default \\ nil)
  defp field(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp field(_value, _key, default), do: default

  defp busy?(assigns), do: not is_nil(assigns.action_label)
  defp active?(run), do: run.status in ~w(queued running waiting cancelling suspending)
  defp resumable?(run), do: run.status in ~w(suspended interrupted)
  defp steerable?(run), do: run.status in ~w(running waiting ready)

  defp checked?(candidate),
    do: candidate.check_status == "passed" and candidate.check_digest == candidate.digest

  defp approved?(candidate, digest),
    do: is_binary(digest) and candidate.approval_digest == digest and candidate.digest == digest

  defp timestamp(nil), do: "—"
  defp timestamp(value), do: Calendar.strftime(value, "%b %d · %H:%M UTC")
  defp short_id(id), do: String.slice(id || "", 0, 8)
  defp short_digest(digest), do: String.slice(digest || "", 0, 12)
  defp label(value), do: value |> to_string() |> String.replace("_", " ")
  defp present?(value), do: value not in [nil, "", %{}, []]
  defp pretty(value) when is_binary(value), do: value
  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp event_text(payload) do
    Enum.find_value(["text", "message", "delta", "summary", "error"], fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp diff_class("+++" <> _), do: "diff-file"
  defp diff_class("---" <> _), do: "diff-file"
  defp diff_class("+" <> _), do: "diff-added"
  defp diff_class("-" <> _), do: "diff-removed"
  defp diff_class("@@" <> _), do: "diff-hunk"
  defp diff_class(_), do: "diff-context"

  defp format_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join("; ", fn {key, {message, _opts}} -> "#{key}: #{message}" end)
  end

  defp format_error(reason) when is_atom(reason) do
    "The host rejected this action: #{label(reason)}. Inspect the current run and candidate before retrying."
  end

  defp format_error(reason) when is_binary(reason), do: String.slice(reason, 0, 1500)

  defp format_error({reason, detail}) when is_atom(reason) do
    "#{label(reason)}: #{detail |> inspect(limit: 8, printable_limit: 1000)}"
  end

  defp format_error(_reason),
    do: "The host rejected this action. No success is assumed; inspect the durable history."

  defp record_process_decision(action, id, question, socket) do
    if field(question, "kind") == "process" do
      run_id = socket.assigns.run.id
      answer = if action == "approve_effect", do: "approve", else: "deny"

      {:noreply,
       begin_action(socket, :answer, "Recording process decision", fn ->
         Editor.answer(run_id, id, answer)
       end)}
    else
      {:noreply, put_flash(socket, :error, "This is a clarification, not a process approval.")}
    end
  end

  defp candidate_action("check_candidate", id, _digest), do: fn -> Candidates.start_check(id) end
  defp candidate_action("cancel_check", id, _digest), do: fn -> Candidates.cancel_check(id) end
  defp candidate_action("start_preview", id, _digest), do: fn -> Candidates.start_preview(id) end
  defp candidate_action("stop_preview", id, _digest), do: fn -> Candidates.stop_preview(id) end

  defp candidate_action("approve_candidate", id, digest),
    do: fn -> Candidates.approve(id, digest) end

  defp candidate_action("publish_candidate", id, digest),
    do: fn -> Candidates.publish(id, digest) end

  defp candidate_action("adopt_candidate", id, digest), do: fn -> Candidates.adopt(id, digest) end

  defp candidate_action("deploy_candidate", id, digest),
    do: fn -> Candidates.deploy(id, digest) end

  defp candidate_action("cancel_deploy", id, _digest), do: fn -> Candidates.cancel_deploy(id) end

  defp action_label(action) do
    %{
      "check_candidate" => "Starting isolated checks",
      "cancel_check" => "Cancelling checks",
      "start_preview" => "Starting isolated preview",
      "stop_preview" => "Stopping preview",
      "approve_candidate" => "Recording exact-digest approval",
      "publish_candidate" => "Publishing reviewed documentation",
      "adopt_candidate" => "Adopting reviewed source",
      "deploy_candidate" => "Requesting configured deployment",
      "cancel_deploy" => "Cancelling owned deployment"
    }[action]
  end

  defp action_receipt("check_candidate"),
    do: "The host accepted the check request. Actual check results appear below."

  defp action_receipt("cancel_check"),
    do: "The host accepted check cancellation. Inspect the check receipt."

  defp action_receipt("start_preview"),
    do: "The host accepted the preview request. The frame appears only after readiness."

  defp action_receipt("stop_preview"), do: "The host accepted preview shutdown."

  defp action_receipt("approve_candidate"),
    do: "The host recorded approval of the reviewed digest."

  defp action_receipt("publish_candidate"),
    do: "The host published the checked, approved documentation snapshot."

  defp action_receipt("adopt_candidate"),
    do: "The host adopted the reviewed source. Running host modules were not replaced."

  defp action_receipt("deploy_candidate"),
    do: "The host accepted deployment. Inspect the deployment status and receipt below."

  defp action_receipt("cancel_deploy"),
    do:
      "The host accepted deployment cancellation. Inspect its cleanup and uncertainty receipt before retrying."

  defp action_receipt(:answer), do: "The host accepted the answer."
  defp action_receipt(:steer), do: "The host accepted your direction."

  defp action_receipt(_action),
    do: "The host accepted the control. Durable run status and events show the outcome."
end
