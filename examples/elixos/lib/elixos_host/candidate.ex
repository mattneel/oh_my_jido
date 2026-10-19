defmodule ElixosHost.Candidate do
  @moduledoc "Delegate to the current Elixos JSON-isolated builder; retain only its durable ID."

  alias OhMyJido.{Context, Tool, Workspace}

  def invoke(context, %{operation: :build, path: path} = request, options)
      when map_size(request) == 2 do
    with {:ok, source} <- Workspace.resolve(context, path),
         true <- File.dir?(source),
         {:ok, provenance} <- provenance(context, options),
         :ok <- Tool.authorize(context, :candidate, %{operation: :build, path: path}),
         {:ok, candidate} <-
           Elixos.Candidate.build(
             source,
             Keyword.put(Keyword.get(options, :build_options, []), :provenance, provenance)
           ) do
      {:ok, %{candidate_id: candidate.id, evidence_dir: candidate.evidence_dir}}
    else
      false -> {:error, :candidate_project_required}
      {:error, _reason} = error -> error
    end
  end

  def invoke(context, %{operation: :test, candidate_id: id} = request, options)
      when map_size(request) == 2 do
    with {:ok, candidate} <- owned_candidate(context, id, options),
         :ok <- Tool.authorize(context, :candidate, %{operation: :test, candidate_id: id}),
         :ok <- Elixos.Candidate.test(candidate),
         {:ok, receipt} <- Elixos.Candidate.evidence(candidate, :test) do
      {:ok,
       %{
         candidate_id: id,
         validated: true,
         receipt: OhMyJido.Redact.sanitize(receipt, [], 65_536)
       }}
    end
  end

  def invoke(context, %{operation: :evidence, candidate_id: id, phase: phase} = request, options)
      when map_size(request) == 3 and phase in [:build, :test] do
    with {:ok, candidate} <- owned_candidate(context, id, options),
         {:ok, receipt} <- Elixos.Candidate.evidence(candidate, phase) do
      {:ok,
       %{candidate_id: id, phase: phase, receipt: OhMyJido.Redact.sanitize(receipt, [], 65_536)}}
    end
  end

  def invoke(context, %{operation: :provenance, generation: number} = request, _options)
      when map_size(request) == 2 and is_integer(number) and number >= 0 do
    if Context.permitted?(context, :candidate),
      do: Elixos.Candidate.provenance(number),
      else: {:error, {:permission_denied, :candidate}}
  end

  def invoke(context, %{operation: :propose, candidate_id: id} = request, options)
      when map_size(request) == 2 do
    if Keyword.get(options, :deployment_enabled, false) do
      with {:ok, candidate} <- owned_candidate(context, id, options),
           :ok <- Tool.authorize(context, :deploy, %{operation: :propose, candidate_id: id}),
           {:ok, generation} <- Elixos.Candidate.propose(candidate) do
        {:ok,
         %{
           candidate_id: id,
           generation: generation,
           next_written: true,
           promotion_acknowledged: false,
           reboot_requested: false
         }}
      end
    else
      {:error, :deployment_disabled}
    end
  end

  def invoke(_context, _request, _options), do: {:error, :invalid_candidate_request}

  defp owned_candidate(context, id, options) when is_binary(id) do
    services = options |> Keyword.get(:build_options, []) |> Keyword.take([:image, :control])

    with true <- Context.permitted?(context, :candidate),
         {:ok, candidate} <- Elixos.Candidate.open(id, services),
         true <- candidate.manifest.provenance.session == identity(context) do
      {:ok, candidate}
    else
      false ->
        if(Context.permitted?(context, :candidate),
          do: {:error, :candidate_owner_mismatch},
          else: {:error, {:permission_denied, :candidate}}
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp owned_candidate(_context, _id, _options), do: {:error, :invalid_candidate}

  defp provenance(context, options) do
    with {:ok, parent} <- parent_generation(options),
         {:ok, model} <- OhMyJido.Models.describe(context.model),
         {:ok, tools} <- tool_revisions(context.tools) do
      {:ok,
       %{
         session: identity(context),
         model: "#{model.provider}:#{model.id}",
         tools: tools,
         parent: parent
       }}
    end
  end

  defp parent_generation(options) do
    case Keyword.get(options, :parent_generation) do
      number when is_integer(number) and number >= 0 ->
        {:ok, number}

      nil ->
        case Elixos.Boot.Env.current() do
          {:ok, %{generation: number}} -> {:ok, number}
          _host -> {:error, :parent_generation_required}
        end

      _invalid ->
        {:error, :invalid_parent_generation}
    end
  end

  defp tool_revisions(tools) do
    Enum.reduce_while(tools, {:ok, %{}}, fn module, {:ok, revisions} ->
      _ = Code.ensure_loaded(module)

      case :code.get_object_code(module) do
        {^module, bytes, _path} ->
          revision = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

          {:cont,
           {:ok,
            Map.put(revisions, module.name(), %{implementation: :elixir, revision: revision})}}

        :error ->
          {:halt, {:error, {:tool_revision_unavailable, module}}}
      end
    end)
  end

  defp identity(context), do: %{runtime: context.runtime, id: context.session_id}
end
