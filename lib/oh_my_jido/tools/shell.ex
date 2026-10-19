defmodule OhMyJido.Tools.Shell do
  @moduledoc "Host-authorized executable/argv launches with child-scoped cwd and environment."

  use Jido.Action,
    name: "shell",
    description:
      "Run an approved executable with scoped cwd/env, separate stdout/stderr, exit status, bounded output and a deadline. Use executable sh and explicit -c args only when a shell is needed.",
    category: "coding",
    tags: ["shell", "process"],
    schema:
      Zoi.object(%{
        executable: Zoi.string() |> Zoi.min(1),
        args: Zoi.array(Zoi.string()) |> Zoi.default([]),
        cwd: Zoi.string() |> Zoi.default("."),
        env: Zoi.map(Zoi.string(), Zoi.string() |> Zoi.nullable(), []) |> Zoi.default(%{}),
        timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
        max_output_bytes: Zoi.integer() |> Zoi.min(0) |> Zoi.optional()
      })

  @doc false
  def capability, do: :exec

  @impl true
  def run(params, context) do
    opts = [cwd: Map.get(params, :cwd, "."), env: Map.get(params, :env, %{})]
    opts = if params[:timeout_ms], do: Keyword.put(opts, :timeout, params.timeout_ms), else: opts

    opts =
      if Map.has_key?(params, :max_output_bytes),
        do: Keyword.put(opts, :max_output_bytes, params.max_output_bytes),
        else: opts

    OhMyJido.Process.run(context, params.executable, Map.get(params, :args, []), opts)
  end
end
