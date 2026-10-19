defmodule OhMyJido.Host do
  @moduledoc """
  Host-owned authorization, questions, credentials, and optional service dispatch.

  Callbacks run in supervised action tasks and must respect their deadline.
  `authorize/4` may return an approval question; the session then pauses that
  effect until `OhMyJido.answer/3` receives the operator's response.
  Credentials are resolved only at the model boundary, never from repository
  configuration or another application's credential files.
  """

  alias OhMyJido.Context

  @callback authorize(Context.t(), atom(), map(), keyword()) ::
              :ok | {:error, term()} | {:approval, map()}
  @callback credentials(Context.t(), term(), keyword()) ::
              {:ok, keyword()} | {:error, term()}
  @callback invoke(Context.t(), atom(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback question(Context.t(), map(), keyword()) ::
              {:ok, term()} | :pending | {:error, term()}

  @doc "Invokes a configured host callback without widening session authority."
  @spec call(Context.t(), atom(), [term()]) :: term()
  def call(%Context{host: {module, opts}} = context, callback, arguments) do
    apply(module, callback, [context | arguments] ++ [opts])
  end
end
