defmodule OhMyJido.Host.Local do
  @moduledoc """
  Reference host for ordinary Mix projects.

  Session grants are checked by the tool dispatcher before this policy runs.
  Sensitive effects require an operator answer. Optional services and credentials
  must be explicitly supplied by the host; no ambient provider keys are imported.
  This policy is not an OS sandbox for shell or Eval code.
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
