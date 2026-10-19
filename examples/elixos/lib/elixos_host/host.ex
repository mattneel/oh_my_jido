defmodule ElixosHost.Host do
  @moduledoc "Elixos owns effects, human consent and account resolution; the library owns coding."
  @behaviour OhMyJido.Host

  alias ElixosHost.Human
  alias OhMyJido.Context

  @human_effects [:exec, :network, :browser_script, :candidate, :deploy, :privileges, :custom]

  @impl true
  def authorize(context, capability, effect, options) do
    cond do
      not Context.permitted?(context, capability) ->
        {:error, {:permission_denied, capability}}

      capability == :deploy and not Keyword.get(options, :deployment_enabled, false) ->
        {:error, :deployment_disabled}

      capability in @human_effects or Map.get(effect, :sensitive, false) ->
        Human.confirm(context, capability, effect, options)

      true ->
        :ok
    end
  end

  @impl true
  def credentials(context, account, options) do
    # The broker is explicitly supplied by the host. No key or account file is read here.
    OhMyJido.Host.Local.credentials(context, account, options)
  end

  @impl true
  def invoke(context, :browser, request, options),
    do: ElixosHost.Browser.invoke(context, request, options)

  def invoke(context, :candidate, request, options),
    do: ElixosHost.Candidate.invoke(context, request, options)

  def invoke(context, :privileges, request, options),
    do: ElixosHost.Privileges.invoke(context, request, options)

  def invoke(context, capability, request, options),
    do: OhMyJido.Host.Local.invoke(context, capability, request, options)

  @impl true
  def question(context, question, options) do
    with {:ok, kind, question_options} <- question_options(question) do
      Human.ask(context, kind, question_options, options)
    end
  end

  defp question_options(%{kind: :effect} = question),
    do:
      {:ok, :confirm,
       [prompt: inspect(OhMyJido.Redact.sanitize(question, [], 4096)), default: false]}

  defp question_options(%{question: prompt} = question) when is_binary(prompt) do
    choices = Map.get(question, :options, [])

    if choices == [] do
      {:ok, :text, [prompt: prompt]}
    else
      labels =
        Enum.map(choices, fn choice -> Map.get(choice, :label, Map.get(choice, "label")) end)

      if Enum.all?(labels, &is_binary/1) and length(Enum.uniq(labels)) == length(labels) do
        kind = if Map.get(question, :multi, false), do: :multi, else: :choice
        {:ok, kind, [prompt: prompt, options: labels, allow_other: false]}
      else
        {:error, :invalid_question}
      end
    end
  end

  defp question_options(_question), do: {:error, :invalid_question}
end
