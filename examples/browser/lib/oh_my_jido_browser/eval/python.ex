defmodule OhMyJidoBrowser.Eval.Python do
  @moduledoc """
  Python Eval through Pyodide (CPython compiled to WebAssembly).

  Each kernel is a Pyodide interpreter in its own Web Worker, so cells never
  block the page. Globals persist across cells; the value of a final
  expression becomes the display value. `print` output streams to the cell
  result, `display(value)` adds a display value, and
  `await tool(name, parameters)` calls a tool the session has granted.

  Interrupting terminates the worker, which stops the cell for certain; the
  next cell needs an explicit reset, which starts a fresh interpreter.
  """

  @behaviour OhMyJido.Eval.Backend

  alias OhMyJidoBrowser.Eval.Kernel

  @functions %{
    open: "(args, actions) => window.ohMyJidoEval.openPython(args, actions)",
    run: "(args) => window.ohMyJidoEval.runPython(args)",
    close: "(args) => window.ohMyJidoEval.closePython(args)"
  }

  @impl true
  def open(_context, opts), do: Kernel.open(@functions, opts)

  @impl true
  def execute(handle, request), do: Kernel.execute(handle, request)

  @impl true
  def interrupt(handle, _execution_id), do: Kernel.close(handle)

  @impl true
  def reset(handle), do: Kernel.reset(handle)

  @impl true
  def close(handle), do: Kernel.close(handle)
end
