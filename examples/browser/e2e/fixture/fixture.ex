defmodule OhMyJidoBrowser.Fixture do
  @moduledoc """
  Scripted model turns for the end-to-end test build (`MIX_ENV=e2e`).

  Any prompt becomes the same run: read the page title in a JavaScript cell,
  ask which accent color to use, compute a value in a Python (Pyodide) cell
  that writes it to the workspace through the tool bridge, edit that file
  against its snapshot, then read it from a JavaScript cell and rewrite the
  title and accent in the live DOM. The tools, the question, both Eval
  kernels, the file effects and the page changes are real; only the model's
  replies are scripted.

  `run_probes/1` runs `OhMyJidoBrowser.Probes` and `OhMyJidoBrowser.EvalProbes`
  inside the browser VM.
  """

  alias Jido.AI.Test.ReActScript
  alias OhMyJidoBrowser.{EvalProbes, Probes}

  @python """
  total = sum(n * n for n in range(10))
  await tool("write", {"path": "notes/python.txt", "snapshot": "missing", "content": str(total)})
  total
  """

  @restyle """
  const file = await tool("read", { path: "notes/python.txt" });
  document.querySelector("#omj-title").textContent = `Popcorn Agent ${file.content}`;
  document.documentElement.style.setProperty("--accent", "#f97316");
  return document.querySelector("#omj-title").textContent;
  """

  @doc "Prompt options carrying the scripted turns for `prompt`."
  @spec prompt_options(String.t(), String.t()) :: keyword()
  def prompt_options(prompt, _workspace) do
    %{
      user: prompt,
      turns: [
        eval("javascript", ~S|document.querySelector("#omj-title").textContent|),
        %{
          type: :tool_call,
          name: "question",
          arguments: %{
            question: "Which accent color should the page use?",
            options: [%{label: "Orange"}, %{label: "Purple"}]
          }
        },
        eval("python", @python),
        %{
          type: :tool_call,
          name: "edit",
          arguments: %{
            path: "notes/python.txt",
            snapshot: OhMyJido.Files.snapshot("285"),
            edits: [%{old: "285", new: "sum=285"}]
          }
        },
        eval("javascript", @restyle),
        %{type: :answer, text: "The title now shows the Python result and the accent is orange."}
      ]
    }
    |> ReActScript.new()
    |> ReActScript.react_opts()
  end

  @doc "Runs the in-browser capability probes against a fresh directory under `root`."
  @spec run_probes(String.t()) :: [map()]
  def run_probes(root) do
    File.rm_rf!(root)
    File.mkdir_p!(root)
    Probes.run(root) ++ EvalProbes.run(root)
  end

  defp eval(language, source),
    do: %{type: :tool_call, name: "eval", arguments: %{language: language, source: source}}
end
