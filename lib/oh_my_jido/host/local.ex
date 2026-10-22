defmodule OhMyJido.Host.Local do
  @moduledoc """
  Provides the default authorization and service policy for coding sessions.

  Tools check session permissions before calling this policy. Effects marked
  `sensitive: true` require human approval; other effects are allowed by this
  policy. This does not mean every shell command asks for approval.

  Configure a credential resolver with
  `credentials: {MyApp.ModelCredentials, []}` on the runtime. It must implement
  `resolve(context, account, options)` and return explicit ReqLLM options.
  No ambient provider keys or other applications' login files are imported.

  Optional services come from the context's adapter map. Missing services return
  `{:error, {:capability_unavailable, capability}}`. Questions remain pending
  until your application answers them through `OhMyJido.answer/3`.

  This policy is not an OS sandbox for shell commands or Eval code.
  """

  @behaviour OhMyJido.Host

  @impl true
  def authorize(_context, _capability, %{sensitive: true} = effect, _opts) do
    {:approval, %{kind: :effect, effect: Map.drop(effect, [:content, :source])}}
  end

  def authorize(_context, _capability, _effect, _opts), do: :ok

  @impl true
  def credentials(_context, nil, _opts), do: {:error, :credentials_required}

  def credentials(context, account, opts) do
    case Keyword.get(opts, :credentials) do
      nil -> {:error, :credentials_required}
      {module, config} -> module.resolve(context, account, config)
    end
  end

  @impl true
  def invoke(context, capability, request, _opts) do
    case Map.fetch(context.adapters, capability) do
      {:ok, {module, opts}} -> module.invoke(context, request, opts)
      :error -> {:error, {:capability_unavailable, capability}}
    end
  end

  @impl true
  def question(_context, _question, _opts), do: :pending
end
