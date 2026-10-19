defmodule OhMyJido.Tools.Skill do
  @moduledoc """
  Trust-gated, session-scoped reuse of Jido.AI Agent Skills.

  The host supplies approved `metadata.skill_roots` and/or approved
  `metadata.skills` entries. Discovery never scans ambient home directories or
  the global skill registry. Files are YAML/Markdown data, never Elixir config.
  `allowed-tools` remains advisory; loading a skill grants no capabilities.
  """
  use Jido.Action,
    name: "skill",
    description:
      "Discover or load host-approved skill guidance; loading never grants tool permissions.",
    schema:
      Zoi.object(%{
        operation: Zoi.enum(["discover", "load"]),
        name: Zoi.string() |> Zoi.optional()
      })

  alias Jido.AI.Actions.Skill.LoadSkill
  alias Jido.AI.Skill.{Activation, Discovery, Resources, Spec}
  alias OhMyJido.{Context, Tool, Workspace}

  def capability, do: :skills

  @impl true
  def run(params, execution_context) do
    operation = Map.get(params, :operation, Map.get(params, "operation"))
    name = Map.get(params, :name, Map.get(params, "name"))

    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, capability(), %{operation: operation, name: name}),
         {:ok, specs} <- catalog(context) do
      perform(operation, name, specs, context)
    end
  end

  @doc "Builds a metadata catalog from explicitly approved host configuration only."
  def catalog(%Context{} = context) do
    roots = setting(context, :skill_roots, [])
    configured = setting(context, :skills, [])

    with {:ok, paths} <- approved_roots(roots, context),
         {:ok, discovered} <-
           Discovery.discover_from(paths, trust: true, max_depth: 6, max_directories: 2_000),
         {:ok, filesystem_specs} <- map_ok(discovered, &Discovery.to_catalog_spec/1),
         {:ok, host_specs} <- map_ok(configured, &approved_spec/1) do
      specs =
        Enum.reduce(host_specs ++ filesystem_specs, %{}, fn spec, acc ->
          Map.put_new(acc, spec.name, spec)
        end)

      {:ok, specs}
    end
  end

  @doc "Clears native activation state; an already-lost native registry is already clear."
  def clear(%Context{} = context) do
    if Process.whereis(Jido.AI.Skill.Registry),
      do: Activation.clear(session_id: scope(context)),
      else: :ok
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp perform("discover", _name, specs, _context) do
    entries =
      specs
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:name, :description]))
      |> Enum.sort_by(& &1.name)

    {:ok, %{skills: entries, authority: :guidance_only}}
  end

  defp perform("load", name, specs, context) when is_binary(name) do
    with {:ok, spec} <- fetch_spec(specs, name),
         :ok <- bounded_spec(spec, context),
         {:ok, loaded} <-
           LoadSkill.run(%{name: name, include_metadata: true}, %{
             LoadSkill.context_skills_key() => %{name => spec},
             Resources.context_policy_key() => %{
               max_file_bytes: max_bytes(context),
               max_text_bytes: max_bytes(context)
             },
             session_id: scope(context)
           }) do
      {:ok, Map.put(loaded, :authority, :guidance_only)}
    end
  end

  defp perform(_operation, _name, _specs, _context), do: {:error, :invalid_skill_operation}

  defp fetch_spec(specs, name) do
    case Map.fetch(specs, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_skill, name}}
    end
  end

  defp approved_roots(roots, context) when is_list(roots) do
    map_ok(roots, fn
      %{approved: true, path: path, scope: :host} when is_binary(path) ->
        if Path.type(path) == :absolute, do: {:ok, path}, else: {:error, :invalid_skill_root}

      %{approved: true, path: path} when is_binary(path) ->
        Workspace.resolve(context, path)

      _untrusted ->
        {:error, :skill_trust_required}
    end)
  end

  defp approved_roots(_roots, _context), do: {:error, :invalid_skill_root}

  defp approved_spec(%{
         approved: true,
         skill: %Spec{source: nil, body_ref: {:inline, body}} = spec
       })
       when is_binary(body),
       do: {:ok, spec}

  defp approved_spec(%{approved: true, skill: module})
       when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module),
      do: Jido.AI.Skill.resolve(module),
      else: {:error, :skill_module_unavailable}
  end

  defp approved_spec(%{approved: true}), do: {:error, :invalid_runtime_skill}
  defp approved_spec(_untrusted), do: {:error, :skill_trust_required}

  defp bounded_spec(%Spec{source: {:file, path}}, context) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= max_bytes(context), do: :ok, else: {:error, :skill_too_large}

      _error ->
        {:error, :skill_source_unavailable}
    end
  end

  defp bounded_spec(%Spec{body_ref: {:inline, body}}, context) when is_binary(body) do
    if byte_size(body) <= max_bytes(context), do: :ok, else: {:error, :skill_too_large}
  end

  defp bounded_spec(_spec, _context), do: {:error, :invalid_runtime_skill}
  defp max_bytes(context), do: Map.get(context.limits, :skill_bytes, 262_144)
  defp scope(context), do: {__MODULE__, context.runtime, context.workspace, context.session_id}

  defp setting(context, key, default) do
    config = Map.get(context.metadata, :runtime_config, %{})

    configured =
      if is_list(config),
        do: Keyword.get(config, key, default),
        else: Map.get(config, key, default)

    Map.get(context.metadata, key, configured)
  end

  defp map_ok(items, function) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case function.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp map_ok(_items, _function), do: {:error, :invalid_skills_configuration}
end
