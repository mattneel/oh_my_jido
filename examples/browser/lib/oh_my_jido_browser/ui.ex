defmodule OhMyJidoBrowser.UI do
  @moduledoc """
  Connects the page to the agent.

  It forwards prompts, answers and model choices from the page, loads local
  models, follows the session's ordered events and writes them into the
  transcript. Updates touch only the status line, the model picker, the
  transcript, the question cards and the key form, so changes the agent makes
  to the rest of the page stay in place. The API key form talks to
  `OhMyJidoBrowser.Credentials` directly; the key never passes through this
  process.
  """

  use GenServer

  alias OhMyJido.Event
  alias OhMyJidoBrowser.{Agent, Credentials, HTML, Models}
  alias Popcorn.JS

  @run_timeout 900_000

  @bind ~S"""
  async ({pid}, {cast}) => {
    const $ = (selector) => document.querySelector(selector);
    $("#omj-composer").onsubmit = (event) => {
      event.preventDefault();
      const input = $("#omj-prompt");
      const text = input.value.trim();
      if (text === "") return;
      input.value = "";
      cast(pid, ["prompt", text]);
    };
    $("#omj-model").onchange = (event) => cast(pid, ["model", event.target.value]);
    $("#omj-approvals").onclick = (event) => {
      const button = event.target.closest("button[data-answer]");
      const card = button?.closest("[data-approval]");
      if (!card) return;
      for (const other of card.querySelectorAll("button")) other.disabled = true;
      cast(pid, ["answer", card.dataset.approval, button.dataset.answer]);
    };
    $("#omj-approvals").onsubmit = (event) => {
      event.preventDefault();
      const card = event.target.closest("[data-approval]");
      const value = card?.querySelector("input")?.value.trim() ?? "";
      if (value !== "") cast(pid, ["answer", card.dataset.approval, value]);
    };
    $("#omj-key-form").onsubmit = (event) => {
      event.preventDefault();
      const input = $("#omj-key");
      const key = input.value.trim();
      input.value = "";
      if (key !== "") cast("Elixir.OhMyJidoBrowser.Credentials", ["save", key]);
    };
    $("#omj-forget").onclick = () => cast("Elixir.OhMyJidoBrowser.Credentials", ["forget"]);
    const page = await window.ohMyJidoLocalModels.catalog();
    return { ...page, probes: new URLSearchParams(location.search).has("probes") };
  }
  """

  @render_models ~S"""
  ({options, selected}) => {
    const select = document.querySelector("#omj-model");
    select.replaceChildren(...options.map(([value, label]) => new Option(label, value)));
    select.value = selected;
    return true;
  }
  """

  @render_status ~S"""
  ({status, state, progress}) => {
    document.querySelector("#omj-status").textContent = status;
    document.querySelector("#app").dataset.state = state;
    document.querySelector("#omj-send").disabled = state !== "ready";
    document.querySelector("#omj-model").disabled = state === "running" || state === "loading-model";
    const bar = document.querySelector("#omj-model-progress");
    bar.hidden = progress === null;
    if (progress !== null) bar.value = progress;
    return true;
  }
  """

  @put_message ~S"""
  ({id, role, html}) => {
    let node = document.getElementById(id);
    if (!node) {
      node = document.createElement("article");
      node.id = id;
      node.className = `message ${role}`;
      document.querySelector("#omj-log").append(node);
    }
    node.innerHTML = html;
    node.scrollIntoView({ block: "end" });
    return true;
  }
  """

  @render_approvals ~S"""
  ({html}) => {
    document.querySelector("#omj-approvals").innerHTML = html;
    return true;
  }
  """

  @render_account ~S"""
  ({needsKey, hasKey}) => {
    document.querySelector("#omj-account").hidden = !needsKey;
    document.querySelector("#omj-forget").hidden = !hasKey;
    return true;
  }
  """

  @load_model "(args, actions) => window.ohMyJidoLocalModels.load(args, actions)"

  @render_probes ~S"""
  ({json}) => {
    let node = document.querySelector("#omj-probes");
    if (!node) {
      node = document.createElement("pre");
      node.id = "omj-probes";
      document.querySelector("#app").append(node);
    }
    node.textContent = json;
    node.dataset.done = "true";
    return true;
  }
  """

  defstruct choice: nil,
            session: nil,
            run: nil,
            streamed?: false,
            streaming: nil,
            state: :booting,
            messages: %{},
            next_id: 1,
            tools: %{},
            approvals: %{},
            tasks: %{},
            usage: nil

  @doc "Starts the page connection."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}, {:continue, :mount}}

  @impl true
  def handle_continue(:mount, state) do
    :ok = JS.await_ready()
    page = JS.run!(@bind, %{pid: self()})
    choice = Agent.default_choice()
    render_models(page, choice)

    if page["probes"] && Agent.fixture(),
      do: {:noreply, run_probes(state)},
      else: {:noreply, select(%{state | choice: choice})}
  end

  # End-to-end builds only: `/?probes` runs the capability probes in this VM.
  defp run_probes(state) do
    state = transition(state, :probing, "Running capability probes…")
    root = Path.join(System.tmp_dir!(), "probes")
    start_task(state, :probes, fn -> Agent.fixture().run_probes(root) end)
  end

  @impl true
  def handle_cast(["prompt", text], %__MODULE__{state: :ready, session: session} = state) do
    case OhMyJido.prompt(session, text, Agent.prompt_options(state.choice, text)) do
      {:ok, run} ->
        state = add_message(state, :user, text)
        state = transition(%{state | run: run, streamed?: false}, :running, "Working…")
        await = fn -> OhMyJido.await(session, run, timeout: @run_timeout) end
        {:noreply, start_task(state, :run, await)}

      {:error, reason} ->
        {:noreply, system(state, "The prompt was not accepted: #{inspect(reason)}")}
    end
  end

  def handle_cast(["answer", id, answer], %__MODULE__{session: session} = state)
      when session != nil do
    case OhMyJido.answer(session, id, answer) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        {:noreply, system(state, "The answer was not accepted: #{inspect(reason)}")}
    end
  end

  def handle_cast(["model", value], %__MODULE__{state: current} = state)
      when current not in [:running, :loading_model] do
    case Models.decode(value) do
      {:ok, choice} when choice != state.choice ->
        {:noreply, state |> close_session() |> Map.put(:choice, choice) |> select()}

      _same_or_invalid ->
        {:noreply, state}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:oh_my_jido, %Event{kind: kind, payload: payload}}, state),
    do: {:noreply, event(kind, payload, state)}

  def handle_info(
        {:wasm, ["progress", progress, text]},
        %__MODULE__{state: :loading_model} = state
      ) do
    {:local, id} = state.choice
    {:noreply, transition(state, :loading_model, "Loading #{id}: #{text}", progress)}
  end

  def handle_info({:credentials, :saved}, %__MODULE__{choice: :openrouter, session: nil} = state),
    do: {:noreply, open_session(state)}

  def handle_info({:credentials, :forgotten}, %__MODULE__{choice: :openrouter} = state),
    do: {:noreply, state |> close_session() |> needs_key()}

  def handle_info({:credentials, :forgotten}, state),
    do: {:noreply, render_account(state, false, false)}

  def handle_info({:credentials, {:error, reason}}, state),
    do: {:noreply, system(state, "The key could not be saved: #{inspect(reason)}")}

  def handle_info({ref, result}, %__MODULE__{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {purpose, tasks} = Map.pop(tasks, ref)
    {:noreply, task_result(purpose, result, %{state | tasks: tasks})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {purpose, tasks} = Map.pop(tasks, ref)
    {:noreply, task_result(purpose, {:error, {:crashed, reason}}, %{state | tasks: tasks})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Tool-call names, reasoning and content parts also arrive as deltas; only
  # answer text belongs in the transcript.
  defp event(:llm_delta, %{delta: delta} = payload, state) when is_binary(delta) do
    if Map.get(payload, :chunk_type, :content) == :content,
      do: stream_text(state, delta),
      else: state
  end

  defp event(:llm_completed, _payload, state), do: %{state | streaming: nil}

  defp event(:tool_started, payload, state) do
    {id, state} = append(state, :tool, "#{payload[:tool_name]} …")
    %{state | streaming: nil, tools: Map.put(state.tools, payload[:tool_call_id], id)}
  end

  defp event(:tool_completed, payload, state) do
    case Map.pop(state.tools, payload[:tool_call_id]) do
      {nil, _tools} ->
        state

      {id, tools} ->
        update_message(%{state | tools: tools}, id, "#{payload[:tool_name]} finished")
    end
  end

  defp event(:approval_requested, %{id: id, question: question}, state),
    do: render_approvals(%{state | approvals: Map.put(state.approvals, id, question)})

  defp event(:approval_answered, %{id: id}, state),
    do: render_approvals(%{state | approvals: Map.delete(state.approvals, id)})

  defp event(:run_completed, _payload, state), do: render_approvals(%{state | approvals: %{}})

  defp event(:request_failed, payload, state) do
    case Map.take(payload, [:code, :status, :reason]) do
      details when details == %{} -> system(state, "The model request failed.")
      details -> system(state, "The model request failed: #{inspect(details)}")
    end
  end

  defp event(_kind, _payload, state), do: state

  defp task_result(:run, {:ok, %{status: :completed, answer: answer} = result}, state) do
    state = if state.streamed?, do: state, else: add_message(state, :assistant, text(answer))
    ready(%{state | run: nil, streaming: nil, usage: Map.get(result, :usage)})
  end

  defp task_result(:run, {:ok, %{status: status}}, state),
    do: ready(system(%{state | run: nil, streaming: nil}, "The run ended: #{status}."))

  defp task_result(:run, {:error, %{error: reason}}, state),
    do: ready(system(%{state | run: nil, streaming: nil}, "The run failed: #{inspect(reason)}"))

  defp task_result(:run, {:error, reason}, state),
    do: ready(system(%{state | run: nil, streaming: nil}, "The run failed: #{inspect(reason)}"))

  defp task_result(:probes, results, state) when is_list(results) do
    JS.run!(@render_probes, %{json: JSON.encode!(results)})
    failed = Enum.count(results, &(&1.status != :passed))
    summary = "Capability probes: #{length(results) - failed} passed, #{failed} failed"
    transition(state, :probes_done, summary)
  end

  defp task_result(:probes, other, state) do
    JS.run!(@render_probes, %{json: JSON.encode!(%{error: inspect(other)})})
    transition(state, :probes_done, "Capability probes crashed")
  end

  defp task_result(:load_model, {:ok, true}, state), do: open_session(state)

  defp task_result(:load_model, {:error, {:js, reason}}, state),
    do: model_failed(state, reason)

  defp task_result(:load_model, other, state), do: model_failed(state, inspect(other))

  defp model_failed(state, reason) do
    state
    |> system("The model could not be loaded: #{reason}")
    |> transition(:model_failed, "Choose another model.")
  end

  defp select(%__MODULE__{choice: :openrouter} = state) do
    if Credentials.load() == :present, do: open_session(state), else: needs_key(state)
  end

  defp select(%__MODULE__{choice: {:local, id}} = state) do
    state = render_account(state, false, false)
    state = transition(state, :loading_model, "Loading #{id}…", 0.0)
    args = %{model: id, listener: self()}
    start_task(state, :load_model, fn -> JS.run(@load_model, args, timeout: :infinity) end)
  end

  defp select(%__MODULE__{choice: :scripted} = state),
    do: open_session(render_account(state, false, false))

  defp open_session(state) do
    with {:ok, session} <-
           OhMyJido.start_session(Agent.runtime(), Agent.session_options(state.choice)),
         :ok <- OhMyJido.subscribe(session, self()) do
      state
      |> render_account(false, state.choice == :openrouter)
      |> Map.merge(%{session: session, usage: nil})
      |> ready()
    else
      {:error, reason} ->
        state
        |> system("The agent could not start: #{inspect(reason)}")
        |> transition(:model_failed, "Choose another model.")
    end
  end

  defp close_session(%__MODULE__{session: nil} = state), do: state

  defp close_session(%__MODULE__{session: session} = state) do
    _ = OhMyJido.stop_session(session)
    %{state | session: nil, run: nil, approvals: %{}}
  end

  defp ready(state),
    do:
      transition(state, :ready, "Ready · #{Models.label(state.choice)}#{usage_text(state.usage)}")

  defp usage_text(%{input_tokens: input, output_tokens: output} = usage)
       when is_integer(input) and is_integer(output) do
    cost =
      case Map.get(usage, :total_cost) do
        cost when is_number(cost) and cost > 0 ->
          " · $#{:erlang.float_to_binary(cost * 1.0, decimals: 6)}"

        _none ->
          ""
      end

    " · last run #{input} input / #{output} output tokens" <> cost
  end

  defp usage_text(_usage), do: ""

  defp needs_key(state) do
    state
    |> transition(:needs_key, "Add an OpenRouter API key to start.")
    |> render_account(true, false)
  end

  defp transition(state, name, status, progress \\ nil) do
    JS.run!(@render_status, %{
      status: status,
      state: name |> Atom.to_string() |> String.replace("_", "-"),
      progress: progress
    })

    %{state | state: name}
  end

  defp start_task(state, purpose, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(OhMyJidoBrowser.Tasks, fun)
    %{state | tasks: Map.put(state.tasks, ref, purpose)}
  end

  defp render_models(%{"models" => models, "webgpu" => webgpu}, choice) do
    local =
      Enum.map(models, fn %{"id" => id, "vram_mb" => vram} ->
        suffix = if webgpu, do: "", else: ", needs WebGPU"
        [Models.encode({:local, id}), "Local: #{id} (~#{vram} MB VRAM#{suffix})"]
      end)

    scripted =
      if Agent.fixture(), do: [[Models.encode(:scripted), "Scripted (test build)"]], else: []

    options =
      scripted ++
        [[Models.encode(:openrouter), "OpenRouter: openai/gpt-6-luna (low reasoning)"]] ++ local

    JS.run!(@render_models, %{options: options, selected: Models.encode(choice)})
  end

  defp stream_text(%__MODULE__{streaming: nil} = state, delta) do
    {id, state} = append(state, :assistant, delta)
    %{state | streaming: id, streamed?: true}
  end

  defp stream_text(%__MODULE__{streaming: id} = state, delta),
    do: update_message(state, id, state.messages[id].text <> delta)

  defp system(state, text), do: add_message(state, :system, text)

  defp add_message(state, role, text), do: state |> append(role, text) |> elem(1)

  defp append(state, role, text) do
    id = state.next_id
    message = %{role: role, text: text}
    put_message(id, message)
    {id, %{state | messages: Map.put(state.messages, id, message), next_id: id + 1}}
  end

  defp update_message(state, id, text) do
    message = %{state.messages[id] | text: text}
    put_message(id, message)
    %{state | messages: Map.put(state.messages, id, message)}
  end

  defp put_message(id, %{role: role, text: text}) do
    role = Atom.to_string(role)

    JS.run!(@put_message, %{
      id: "omj-msg-#{id}",
      role: role,
      html:
        ~s(<span class="role">#{role}</span><div class="text">) <> HTML.escape(text) <> "</div>"
    })
  end

  defp render_approvals(state) do
    html =
      state.approvals
      |> Enum.sort()
      |> Enum.map(fn {id, question} -> approval_html(id, question) end)
      |> IO.iodata_to_binary()

    JS.run!(@render_approvals, %{html: html})
    state
  end

  defp render_account(state, needs_key, has_key) do
    JS.run!(@render_account, %{needsKey: needs_key, hasKey: has_key})
    state
  end

  defp approval_html(id, question) do
    [
      ~s(<div class="approval" data-approval="),
      HTML.escape(id),
      ~s(">),
      approval_body(question),
      "</div>"
    ]
  end

  defp approval_body(%{kind: :effect, effect: effect}) do
    [
      "<p>The agent wants to <strong>",
      HTML.escape(Map.get(effect, :operation, "run an action")),
      "</strong> <code>",
      HTML.escape(Map.get(effect, :path, "")),
      "</code>.</p>",
      ~s(<button type="button" data-answer="approve">Approve</button> ),
      ~s(<button type="button" data-answer="deny">Deny</button>)
    ]
  end

  defp approval_body(%{question: text} = question) do
    case Map.get(question, :options, []) do
      [] ->
        [
          "<p>",
          HTML.escape(text),
          ~s(</p><form><input autocomplete="off"><button>Answer</button></form>)
        ]

      options ->
        ["<p>", HTML.escape(text), "</p>", Enum.map(options, &option_button/1)]
    end
  end

  defp approval_body(question), do: ["<p>", HTML.escape(inspect(question)), "</p>"]

  defp option_button(option) do
    label = option_label(option)

    [
      ~s(<button type="button" data-answer="),
      HTML.escape(label),
      ~s(">),
      HTML.escape(label),
      "</button> "
    ]
  end

  # Options come from the model as JSON (string keys) or from scripts (atom keys).
  defp option_label(option) when is_map(option) do
    option = Map.new(option, fn {key, value} -> {to_string(key), value} end)
    to_string(option["label"] || option["value"] || inspect(option))
  end

  defp option_label(option), do: to_string(option)

  defp text(answer) when is_binary(answer), do: answer
  defp text(answer), do: inspect(answer)
end
