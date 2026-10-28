defmodule Mix.Tasks.OhMyJidoBrowser.Assets do
  @shortdoc "Copies Pyodide, WebLLM and the shared bridge into public/"
  @moduledoc """
  Copies the browser runtimes the page loads from its own origin:

    * Pyodide's core files into `public/pyodide/`, for Python Eval
    * WebLLM's bundle into `public/vendor/web-llm/`, for local models
    * The `web_llm` dependency's bridge and worker into `public/vendor/web_llm/`

  Run `mix deps.get` and `npm ci` first. The copied directories are generated
  and ignored by Git.
  """

  use Mix.Task

  @files [
    {"node_modules/pyodide",
     ~w(pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json),
     "public/pyodide"},
    {"node_modules/@mlc-ai/web-llm/lib", ~w(index.js), "public/vendor/web-llm"}
  ]

  @impl Mix.Task
  def run(_args) do
    bridge_source = Path.join(Mix.Project.deps_paths()[:web_llm], "priv/static")

    files = [
      {bridge_source, ~w(web_llm.js web_llm_worker.js), "public/vendor/web_llm"}
      | @files
    ]

    for {source, files, target} <- files do
      File.mkdir_p!(target)
      Enum.each(files, &copy!(Path.join(source, &1), Path.join(target, &1)))
      Mix.shell().info("#{source} -> #{target}")
    end
  end

  defp copy!(from, to) do
    unless File.regular?(from) do
      Mix.raise("#{from} is missing; run `mix deps.get` and `npm ci` in #{File.cwd!()} first")
    end

    File.cp!(from, to)
  end
end
