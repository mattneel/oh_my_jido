defmodule OhMyJido.Tools.Git do
  @moduledoc "Validated, host-controlled Git inspection, commits and worktrees; no arbitrary Git commands."

  use Jido.Action,
    name: "git",
    description:
      "Inspect status/diff/log/patch context, commit explicit paths with sensitive approval, or create/remove an approved worktree. Mutations require edit permission; history rewriting and force removal are unavailable.",
    schema:
      Zoi.object(%{
        operation:
          Zoi.enum([
            "status",
            "diff",
            "log",
            "patch_context",
            "commit",
            "worktree_add",
            "worktree_remove"
          ]),
        repo: Zoi.string() |> Zoi.default("."),
        paths: Zoi.array(Zoi.string()) |> Zoi.default([]),
        message: Zoi.string() |> Zoi.optional(),
        path: Zoi.string() |> Zoi.optional(),
        revision: Zoi.string() |> Zoi.optional(),
        base: Zoi.string() |> Zoi.optional(),
        cached: Zoi.boolean() |> Zoi.default(false),
        context_lines: Zoi.integer() |> Zoi.min(0) |> Zoi.max(100) |> Zoi.default(3),
        limit: Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.default(20),
        timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
        max_output_bytes: Zoi.integer() |> Zoi.min(0) |> Zoi.optional()
      })

  alias OhMyJido.Git, as: Repository

  @doc "Returns the Action category."
  def category, do: "coding"

  @doc "Returns tags that classify this Action."
  def tags, do: ["git", "repository"]

  @doc false
  def capability, do: :git

  @impl true
  def run(params, context) do
    opts = options(params)

    case params.operation do
      "status" -> Repository.status(context, opts)
      "diff" -> Repository.diff(context, opts)
      "log" -> Repository.log(context, opts)
      "patch_context" -> Repository.patch_context(context, opts)
      "commit" -> Repository.commit(context, Map.get(params, :message), opts)
      "worktree_add" -> Repository.create_worktree(context, Map.get(params, :path), opts)
      "worktree_remove" -> Repository.remove_worktree(context, Map.get(params, :path), opts)
      _unsupported -> {:error, :unsupported_git_operation}
    end
  end

  defp options(params) do
    opts =
      params
      |> Map.take([
        :repo,
        :paths,
        :revision,
        :base,
        :cached,
        :context_lines,
        :limit,
        :max_output_bytes
      ])
      |> Enum.to_list()

    if params[:timeout_ms], do: Keyword.put(opts, :timeout, params.timeout_ms), else: opts
  end
end
