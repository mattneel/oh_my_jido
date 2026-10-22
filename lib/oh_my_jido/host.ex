defmodule OhMyJido.Host do
  @moduledoc """
  Defines how your application authorizes effects, resolves credentials, and supplies services.

  Configure a module implementing this behaviour as `host: {MyApp.CodingHost, []}`.
  `OhMyJido.Host.Local` is the default policy and works with explicit credential
  resolvers and adapter bindings.

  The callbacks receive the trusted session context and configured options.
  `authorize/4` can approve, deny, or request a human decision. In a managed
  session, an approval request waits for `OhMyJido.answer/3`. `question/3`
  can answer immediately or return `:pending` for your application's UI.

  Credentials are resolved for each model request, not read from repository
  configuration or another application's login files. Callbacks are trusted
  application code: respect deadlines and clean up resources you own.
  See the Permissions and approvals and Models and accounts guides.
  """

  alias OhMyJido.Context

  @doc "Allows or denies an effect, or returns `{:approval, question}` for a human decision."
  @callback authorize(Context.t(), atom(), map(), keyword()) ::
              :ok | {:error, term()} | {:approval, map()}
  @doc "Resolves an opaque account reference to explicit per-request ReqLLM options."
  @callback credentials(Context.t(), term(), keyword()) ::
              {:ok, keyword()} | {:error, term()}
  @doc "Dispatches a structured request to an application-supplied optional service."
  @callback invoke(Context.t(), atom(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @doc "Answers a structured question, returns `:pending`, or reports an error."
  @callback question(Context.t(), map(), keyword()) ::
              {:ok, term()} | :pending | {:error, term()}

  @doc "Invokes a configured host callback without widening session authority."
  @spec call(Context.t(), atom(), [term()]) :: term()
  def call(%Context{host: {module, opts}} = context, callback, arguments) do
    apply(module, callback, [context | arguments] ++ [opts])
  end
end
