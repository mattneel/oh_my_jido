defmodule OhMyJidoBrowser.Eval.JavaScript do
  @moduledoc """
  JavaScript Eval in the page itself, through `new Function`.

  Cells run with full access to the live page: the DOM, styles, `window` and
  `fetch`. Values assigned to new names, and top-level `let`, `const`, `var`,
  `function` and `class` declarations, persist across cells in a per-kernel
  scope. A cell may `return` a value or be a single expression; `console`
  output streams to the cell result, `display(value)` adds a display value and
  `await tool(name, parameters)` calls a tool the session has granted.

  Cells share the page's main thread, so a timed-out cell cannot be stopped:
  the kernel is invalidated and its cleanup reported as uncertain.
  """

  @behaviour OhMyJido.Eval.Backend

  alias OhMyJidoBrowser.Eval.Kernel

  @functions %{
    open: "(args) => window.ohMyJidoEval.openJavaScript(args)",
    run: "(args, actions) => window.ohMyJidoEval.runJavaScript(args, actions)",
    close: "(args) => window.ohMyJidoEval.closeJavaScript(args)"
  }

  @impl true
  def open(_context, opts), do: Kernel.open(@functions, opts)

  @impl true
  def execute(handle, request), do: Kernel.execute(handle, request)

  @impl true
  def interrupt(_handle, _execution_id), do: {:error, :runs_on_page_thread}

  @impl true
  def reset(handle), do: Kernel.reset(handle)

  @impl true
  def close(handle), do: Kernel.close(handle)
end
