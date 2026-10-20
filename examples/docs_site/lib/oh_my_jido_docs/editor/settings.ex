defmodule OhMyJidoDocs.Editor.Settings do
  @moduledoc false

  alias Jido.AI.Test.ReActScript
  alias OhMyJido.Runtime
  alias OhMyJidoDocs.Editor.{Host, Snapshot}

  @runtime OhMyJidoDocs.Coding
  @tools [
    OhMyJido.Tools.Read,
    OhMyJido.Tools.Edit,
    OhMyJido.Tools.Write,
    OhMyJido.Tools.Search,
    OhMyJido.Tools.List,
    OhMyJido.Tools.Git,
    OhMyJido.Tools.Question
  ]

  def prepare(attrs, opts) when is_map(attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in [:task, :mode, "task", "mode"])),
         false <- Map.has_key?(attrs, :task) and Map.has_key?(attrs, "task"),
         false <- Map.has_key?(attrs, :mode) and Map.has_key?(attrs, "mode"),
         task when is_binary(task) <- Map.get(attrs, :task, Map.get(attrs, "task")),
         true <- String.valid?(task) and byte_size(task) in 1..16_384 and String.trim(task) != "",
         mode when mode in ["docs", "coding"] <-
           Map.get(attrs, :mode, Map.get(attrs, "mode", "docs")),
         :ok <- request_options(opts) do
      {:ok, %{task: Snapshot.text(task, 16_384), mode: mode}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_run_attributes}
    end
  end

  def prepare(_attrs, _opts), do: {:error, :invalid_run_attributes}

  def request_options(opts) do
    with true <- Application.get_env(:oh_my_jido_docs, :editor_enabled, false),
         true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:llm_opts, :max_iterations])),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- valid_iterations?(Keyword.get(opts, :max_iterations)),
         {:ok, config} <- Runtime.config(@runtime),
         :ok <- model(),
         :ok <- script_or_credentials(Keyword.get(opts, :llm_opts, []), config) do
      :ok
    else
      false -> {:error, :invalid_run_options}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_run_options}
    end
  end

  def session_options(run) do
    tools = if run.mode == "coding", do: @tools ++ [OhMyJido.Tools.Shell], else: @tools

    permissions =
      if run.mode == "coding",
        do: [:read, :edit, :git, :ask, :exec],
        else: [:read, :edit, :git, :ask]

    [
      id: run.session_id,
      workspace: run.workspace,
      role: :coding,
      model: Application.fetch_env!(:oh_my_jido_docs, :model),
      account: Application.get_env(:oh_my_jido_docs, :model_account),
      host: {Host, []},
      tools: tools,
      permissions: permissions,
      metadata: %{docs_run_id: run.id, docs_mode: run.mode}
    ]
  end

  defp model do
    case Application.get_env(:oh_my_jido_docs, :model) do
      model when is_binary(model) and byte_size(model) > 0 ->
        case OhMyJido.Models.resolve(model) do
          {:ok, _model} -> :ok
          {:error, _reason} = error -> error
        end

      _missing ->
        {:error, :model_not_configured}
    end
  end

  defp script_or_credentials([], _config) do
    key = Application.get_env(:oh_my_jido_docs, :model_api_key)
    account = Application.get_env(:oh_my_jido_docs, :model_account)

    if is_binary(key) and String.trim(key) != "" and OhMyJido.Models.account_reference?(account),
      do: :ok,
      else: {:error, :credentials_required}
  end

  defp script_or_credentials(
         [
           jido_ai_model_call: callback,
           jido_ai_react_script: %ReActScript{id: id, user: user, turns: turns}
         ],
         config
       )
       when is_binary(id) and is_binary(user) and is_list(turns) and turns != [] do
    cond do
      callback != (&ReActScript.model_call/2) -> {:error, :invalid_run_options}
      not Keyword.get(config, :allow_test_scripts, false) -> {:error, :test_scripts_not_enabled}
      true -> :ok
    end
  end

  defp script_or_credentials(_opts, _config), do: {:error, :invalid_run_options}

  defp valid_iterations?(nil), do: true
  defp valid_iterations?(value), do: is_integer(value) and value > 0
end
