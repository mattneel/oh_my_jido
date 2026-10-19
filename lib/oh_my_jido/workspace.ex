defmodule OhMyJido.Workspace do
  @moduledoc """
  Canonical workspace paths over Jido's existing file-root policy.

  Every resolution supplies an explicit root to `Jido.Tools.Files.resolve_path/2`;
  its application-wide roots remain an additional restriction. The dependency
  returns a lexical path and accepts missing ancestors, so this adapter also
  resolves symlinks, requires existing parents, and returns canonical paths.
  `allow_missing: true` permits only a missing final component.

  Resolution is repeated at filesystem effects. It is not an OS sandbox against
  a hostile process continuously replacing directories between system calls.
  Hosts requiring that guarantee must enforce an OS filesystem boundary.
  """

  alias OhMyJido.Context

  @max_symlinks 40

  @doc "Validates an existing directory and returns its canonical absolute root."
  @spec new(String.t()) :: {:ok, String.t()} | {:error, term()}
  def new(root) do
    with :ok <- valid_path(root),
         {:ok, canonical} <- canonical(Path.expand(root), false),
         {:ok, %File.Stat{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      {:ok, _stat} -> {:error, :enotdir}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolves a path within the grant without changing the VM working directory."
  @spec resolve(Context.t() | map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(execution_context, path, opts \\ []) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- valid_path(path),
         {:ok, root} <- stable_root(context.workspace),
         :ok <- reject_traversal(path),
         expanded = Path.expand(path, root),
         :ok <- inside(expanded, root),
         {:ok, resolved} <- canonical(expanded, Keyword.get(opts, :allow_missing, false), root),
         :ok <- inside(resolved, root),
         {:ok, _path} <- jido_resolve(resolved, root) do
      {:ok, resolved}
    end
  end

  @doc "Returns a stable path relative to the workspace, or a confinement error."
  @spec relative(Context.t() | map(), String.t()) :: String.t() | {:error, term()}
  def relative(execution_context, path) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- valid_path(path),
         :ok <- reject_traversal(path),
         root = Path.expand(context.workspace),
         expanded = Path.expand(path, root),
         :ok <- inside(expanded, root) do
      if expanded == root, do: ".", else: Path.relative_to(expanded, root)
    end
  end

  defp stable_root(root) do
    with :ok <- valid_path(root),
         true <- Path.type(root) == :absolute,
         {:ok, canonical} <- new(root),
         true <- canonical == Path.expand(root) do
      {:ok, canonical}
    else
      false -> {:error, :outside_workspace}
      {:error, _reason} = error -> error
    end
  end

  defp valid_path(path) when is_binary(path) do
    if path != "" and String.valid?(path) and not String.contains?(path, <<0>>) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  defp valid_path(_path), do: {:error, :invalid_path}

  defp reject_traversal(path) do
    if ".." in Path.split(path), do: {:error, :outside_workspace}, else: :ok
  end

  defp inside(_path, nil), do: :ok

  defp inside(_path, "/"), do: :ok

  defp inside(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, :outside_workspace}
    end
  end

  defp jido_resolve(path, root) do
    case Jido.Tools.Files.resolve_path(path, %{allowed_file_roots: [root]}) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _reason} -> {:error, :outside_workspace}
    end
  end

  defp canonical(path, allow_missing, boundary \\ nil) do
    [root | parts] = Path.split(path)
    resolve_parts(root, parts, allow_missing, 0, boundary)
  end

  defp resolve_parts(path, [], _allow_missing, _depth, _boundary), do: {:ok, path}

  defp resolve_parts(parent, [part | rest], allow_missing, depth, boundary) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} when depth >= @max_symlinks ->
        {:error, :eloop}

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path),
             expanded = Path.expand(target, parent),
             :ok <- inside(expanded, boundary) do
          [root | parts] = Path.split(expanded)
          resolve_parts(root, parts ++ rest, allow_missing, depth + 1, boundary)
        end

      {:ok, %File.Stat{type: type}} when rest != [] and type != :directory ->
        {:error, :enotdir}

      {:ok, _stat} ->
        resolve_parts(path, rest, allow_missing, depth, boundary)

      {:error, :enoent} when allow_missing and rest == [] ->
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
