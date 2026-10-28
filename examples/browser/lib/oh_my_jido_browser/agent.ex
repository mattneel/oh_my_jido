defmodule OhMyJidoBrowser.Agent do
  @moduledoc """
  Runtime, session and prompt settings for the browser agent.

  The agent evaluates JavaScript in its own page and Python in Pyodide
  through the standard Eval tool, reads and writes files in an in-memory
  workspace, and can ask the person questions. `OhMyJidoBrowser.Models` lists
  the models it can run on. A build that sets
  `config :oh_my_jido_browser, fixture: Module` also offers that module's
  scripted model turns; only the end-to-end test build does.
  """

  alias OhMyJidoBrowser.{Credentials, Models, Workspace}

  @runtime OhMyJidoBrowser.Runtime
  @tools [
    OhMyJido.Tools.Eval,
    OhMyJido.Tools.Read,
    OhMyJido.Tools.Edit,
    OhMyJido.Tools.Write,
    OhMyJido.Tools.Question
  ]
  @permissions [:eval, :read, :edit, :ask]

  @system_prompt """
  You run entirely inside the user's web browser, in an Erlang VM compiled to WebAssembly. The page the user is looking at is your own interface, and you can change it.

  The page is not a file in your workspace: change it with the eval tool. JavaScript cells (language "javascript") run in the page itself, with full access to the DOM, styles and window. A cell may be a single expression or a function body that returns a value; console output is captured. Python cells run in Pyodide in a separate worker. In both languages, values persist across cells and `await tool(name, parameters)` calls your other tools. Changes to the page appear immediately and last until it reloads.

  For example, to rename the page heading, call eval with language "javascript" and source `document.querySelector("#omj-title").textContent = "New title"`.

  Useful page landmarks: #omj-title (the heading), #omj-status (status line), #omj-log (the transcript), #omj-composer (the prompt box). The stylesheet uses CSS variables on :root: --accent, --background, --surface, --text and --muted.

  You also have an in-memory workspace for files (read, edit, write), lost on reload. Shell commands, search and Git are not available in the browser.
  """

  @doc "Name of the supervised Oh-My-Jido runtime."
  @spec runtime() :: atom()
  def runtime, do: @runtime

  @doc "Scripted-model module, present only in the end-to-end test build."
  @spec fixture() :: module() | nil
  def fixture, do: Application.get_env(:oh_my_jido_browser, :fixture)

  @doc "The model the page starts with."
  @spec default_choice() :: Models.choice()
  def default_choice, do: if(fixture(), do: :scripted, else: :openrouter)

  @doc "Options for `{OhMyJido, ...}`."
  @spec runtime_options() :: keyword()
  def runtime_options do
    [
      name: @runtime,
      credentials: {Credentials, []},
      tools: @tools,
      system_prompt: @system_prompt,
      allow_test_scripts: fixture() != nil,
      tool_timeout_ms: 180_000,
      max_sessions: 4,
      max_active: 1,
      eval: [
        backends: %{
          javascript: [backend: OhMyJidoBrowser.Eval.JavaScript],
          python: [backend: OhMyJidoBrowser.Eval.Python, boot_timeout: 120_000]
        },
        max_kernels: 4,
        limits: [max_timeout: 300_000]
      ]
    ]
  end

  @doc "Options for `OhMyJido.start_session/2` with the given model."
  @spec session_options(Models.choice()) :: keyword()
  def session_options(choice) do
    base = [workspace: Workspace.root(), permissions: @permissions, model: Models.spec(choice)]

    case Models.account(choice) do
      nil -> base
      account -> [{:account, account} | base]
    end
  end

  @doc "Options for `OhMyJido.prompt/3` with the given model."
  @spec prompt_options(Models.choice(), String.t()) :: keyword()
  def prompt_options(:scripted, text), do: fixture().prompt_options(text, Workspace.root())
  def prompt_options(:openrouter, _text), do: [llm_opts: [reasoning_effort: :low]]
  def prompt_options({:local, _id}, _text), do: []
end
