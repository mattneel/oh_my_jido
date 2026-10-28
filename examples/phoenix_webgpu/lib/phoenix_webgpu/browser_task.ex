defmodule PhoenixWebGPU.BrowserTask do
  @moduledoc "Delegates page work with a host-selected role, workspace and tab routing header."
  use Jido.Action,
    name: "browser_task",
    description:
      "Delegate a task about the user's current page to their browser GPU, then return the child's result.",
    schema: Zoi.object(%{task: Zoi.string()})

  alias OhMyJido.{Context, SessionRef, Tool}

  @doc "Only the parent is granted delegation."
  @spec capability() :: :delegate
  def capability, do: :delegate

  @impl true
  def run(%{task: task}, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, :delegate),
         parent = %SessionRef{runtime: context.runtime, id: context.session_id},
         {:ok, child} <- OhMyJido.delegate(parent, task, child_options(context)),
         {:ok, result} <- OhMyJido.await_child(parent, child.tag, timeout: 540_000) do
      result = Map.take(result, [:status, :answer, :error, :usage])
      send(context.metadata.browser_observer, {:browser_result, result})
      {:ok, result}
    end
  end

  # Local models can stay silent through a long prefill on slower GPUs, so the
  # child waits up to five minutes between stream updates (ReqLLM's
  # `receive_timeout`, 30 seconds by default).
  defp child_options(context) do
    [
      role: context.metadata.browser_role,
      writable: true,
      permissions: [:custom],
      workspace: context.metadata.browser_workspace,
      req_http_options: [headers: [{"x-web-llm-client", context.metadata.browser_client}]],
      llm_opts: [receive_timeout: 300_000],
      max_iterations: 8
    ]
  end
end
