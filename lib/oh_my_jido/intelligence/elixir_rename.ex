defmodule OhMyJido.Intelligence.ElixirRename do
  @moduledoc """
  Bounded Elixir rename planning for the host-configured LSP adapter.

  Source parsing supplies authored identifier tokens and the complete nonignored
  `.ex`/`.exs` inventory. The configured native language server supplies semantic
  definition and reference identity. Neither a spelling match nor a nonempty
  references response proves coverage. Every plausible authored occurrence is
  checked against native definitions; incomplete or generated identity fails
  closed. No project code is compiled, expanded, evaluated, or loaded here.

  Functions include their overlapping default-arity/multiclause family. Variables
  use the provider's binding identity, including rebindings and captures. Modules
  support same-namespace leaf renames, retaining explicit local alias names and
  renaming implicit ones, including aliases introduced by bare nested module
  declarations. Qualified nested declarations without proven alias metadata,
  namespace moves, generated/dynamic identity, and unprovable destination
  import/alias capture, including untouched module references, are rejected,
  not approximated.
  Opaque macro/callback scopes and unclassified callees are rejected. The audited
  ElixirLS 0.31.1 profile uses native parser-environment/type-info commands and
  declaration hover preambles, never documentation bodies, to establish caller
  bindings, namespace availability, and SDK callee kinds. Actual inventory bytes
  are synchronized to owned native buffers when needed; source fingerprints and
  versions are checked before and after queries. Source publication belongs to
  TextEdits, not this planner.
  """

  alias OhMyJido.{Context, Files, Search, Workspace}
  alias OhMyJido.Intelligence.ElixirRename.{Bindings, Hover, Namespace, Source, Sync}
  alias OhMyJido.Intelligence.{Stdio, TextEdits}

  @defaults %{files: 128, bytes: 8_388_608, file_bytes: 1_048_576, candidates: 2_000}
  @reserved ~w(after alias and case catch cond def defdelegate defexception defguard defguardp defimpl defmacro defmacrop defmodule defp defprotocol defstruct do else end false fn for if import in nil not or quote raise receive require rescue true try unless unquote unquote_splicing use when with)

  @spec plan(map(), GenServer.server(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def plan(execution_context, server, request, opts) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- valid_request(request),
         {:ok, limits} <- limits(context, opts),
         {:ok, inventory} <- inventory(context, limits),
         {:ok, relative} <- relative(context, request.path),
         {:ok, source} <- source(inventory, relative),
         :ok <- requested_snapshots(inventory, relative, request),
         {:ok, selected} <- Source.at(source, position(request)),
         {:ok, identity} <- Stdio.bind(server, context),
         {:ok, versions, inputs, synchronization} <-
           Sync.documents(context, server, inventory, opts),
         resolver = %{
           context: context,
           server: server,
           inventory: inventory,
           tokens:
             inventory |> Enum.sort() |> Enum.flat_map(fn {_path, source} -> source.tokens end),
           imports: Enum.flat_map(inventory, fn {_path, source} -> source.imports end),
           cache: %{},
           proofs: %{},
           locations: 0,
           binding_proofs: [],
           callable_cache: %{},
           provider_info: Map.get(identity, :server_info),
           stale_references: [],
           request_counts: %{},
           requests: 0,
           limit: limits.candidates,
           timeout: Keyword.get(opts, :timeout_ms, 10_000)
         },
         {:ok, target, resolver} <- selected_definition(selected, resolver),
         {:ok, occurrences, symbol, resolver} <-
           rename(target, selected, request.new_name, resolver),
         symbol =
           Map.put(symbol, :native_definition, Map.get(resolver.proofs, Source.key(target))),
         :ok <- edit_bounds(occurrences),
         {:ok, reference_count, resolver} <- corroborate(target, selected, occurrences, resolver),
         :ok <- unchanged(context, inventory, limits),
         :ok <- Sync.current(server, versions, inputs),
         {:ok, edit} <- workspace_edit(context, occurrences, versions) do
      {:ok, edit,
       %{
         backend: :elixir,
         provider: :language_server_definition_references,
         certainty: :bounded_source_verified,
         symbol: symbol,
         scope: %{
           kind: :workspace_sources,
           glob: "**/*.{ex,exs}",
           hidden: true,
           ignore: true,
           complete: true,
           inventory:
             inventory
             |> Map.values()
             |> Enum.sort_by(& &1.path)
             |> Enum.map(&Map.take(&1, [:path, :snapshot])),
           source_bytes:
             Enum.reduce(inventory, 0, fn {_path, file}, bytes ->
               bytes + byte_size(file.content)
             end)
         },
         occurrences: length(occurrences),
         native_reference_locations: reference_count,
         native_stale_reference_exclusions: Enum.reverse(resolver.stale_references),
         native_inputs: %{
           source_fingerprints_verified: true,
           documents: inputs,
           synchronized: synchronization
         },
         native_definition_requests:
           Map.get(resolver.request_counts, "textDocument/definition", 0),
         native_module_symbol_requests: Map.get(resolver.request_counts, "workspace/symbol", 0),
         native_hover_requests: Map.get(resolver.request_counts, "textDocument/hover", 0),
         native_completion_requests:
           Map.get(resolver.request_counts, "textDocument/completion", 0),
         native_environment_or_type_requests:
           Map.get(resolver.request_counts, "workspace/executeCommand", 0),
         native_callable_kinds: %{
           verified_external_calls: map_size(resolver.callable_cache),
           server_info: if(is_map(resolver.provider_info), do: resolver.provider_info)
         },
         native_requests: resolver.requests,
         reference_coverage: :corroborated_with_exhaustive_source_candidates
       }}
    else
      false -> {:error, :elixir_rename_server_documents_changed}
      {:error, _} = error -> error
    end
  end

  defp valid_request(%{path: path, line: line, character: character, new_name: name})
       when is_binary(path) and is_integer(line) and line >= 0 and is_integer(character) and
              character >= 0 and is_binary(name) do
    if String.valid?(name) and byte_size(name) in 1..255 and not String.contains?(name, <<0>>),
      do: :ok,
      else: {:error, :elixir_rename_invalid_name}
  end

  defp valid_request(_request), do: {:error, :elixir_rename_invalid_request}

  defp limits(context, opts) do
    Enum.reduce_while(@defaults, {:ok, %{}}, fn {key, maximum}, {:ok, acc} ->
      option =
        case key do
          :files -> :rename_max_files
          :bytes -> :rename_max_bytes
          :file_bytes -> :rename_max_file_bytes
          :candidates -> :rename_max_candidates
        end

      ceiling = Map.get(context.limits, option, maximum)
      requested = Keyword.get(opts, option, ceiling)

      if is_integer(ceiling) and ceiling > 0 and is_integer(requested) and requested > 0 do
        {:cont, {:ok, Map.put(acc, key, min(maximum, min(ceiling, requested)))}}
      else
        {:halt, {:error, :elixir_rename_invalid_limit}}
      end
    end)
  end

  defp discover(context, limits) do
    with {:ok, found} <-
           Search.files(context, ".",
             glob: "**/*.{ex,exs}",
             hidden: true,
             ignore: true,
             max_files: limits.files,
             max_results: limits.files
           ),
         false <- found.truncated,
         true <- Enum.all?(found.skipped, fn {_kind, count} -> count == 0 end) do
      {:ok, found.paths}
    else
      true -> {:error, :elixir_rename_inventory_limit}
      false -> {:error, :elixir_rename_incomplete_inventory}
      {:error, _} = error -> error
    end
  end

  defp inventory(context, limits) do
    with {:ok, paths} <- discover(context, limits) do
      Enum.reduce_while(paths, {:ok, %{}, 0}, fn path, acc ->
        inventory_file(path, acc, context, limits)
      end)
      |> case do
        {:ok, files, _bytes} -> {:ok, files}
        error -> error
      end
    end
  end

  defp inventory_file(path, {:ok, files, bytes}, context, limits) do
    with {:ok, file} <- Files.read_bytes(context, path, max_file_bytes: limits.file_bytes),
         false <- file.binary,
         true <- bytes + byte_size(file.content) <= limits.bytes,
         {:ok, parsed} <- Source.parse(file) do
      {:cont, {:ok, Map.put(files, file.path, parsed), bytes + byte_size(file.content)}}
    else
      true -> {:halt, {:error, {:elixir_rename_binary_source, path}}}
      false -> {:halt, {:error, :elixir_rename_inventory_bytes}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp source(inventory, path) do
    case Map.fetch(inventory, path) do
      {:ok, file} -> {:ok, file}
      :error -> {:error, {:elixir_rename_source_outside_inventory, path}}
    end
  end

  defp relative(context, path) do
    with {:ok, absolute} <- Workspace.resolve(context, path),
         relative when is_binary(relative) <- Workspace.relative(context, absolute) do
      {:ok, relative}
    end
  end

  defp requested_snapshots(inventory, path, request) do
    snapshots = Map.put(Map.get(request, :snapshots, %{}), path, Map.get(request, :snapshot))

    Enum.reduce_while(snapshots, :ok, fn
      {_path, nil}, :ok ->
        {:cont, :ok}

      {path, expected}, :ok ->
        case Map.get(inventory, path) do
          %{snapshot: ^expected} ->
            {:cont, :ok}

          %{snapshot: actual} ->
            {:halt, {:error, {:elixir_rename_stale_snapshot, path, expected, actual}}}

          nil ->
            {:halt, {:error, {:elixir_rename_snapshot_outside_inventory, path}}}
        end
    end)
  end

  defp selected_definition(%{role: :alias_name}, _resolver),
    do: {:error, :elixir_rename_explicit_alias_binding_not_module}

  defp selected_definition(%{kind: :import_qualifier} = selected, resolver) do
    imports = all_imports(resolver)
    import = Enum.find(imports, &(Source.key(&1.target) == selected.import_target))

    with true <- not is_nil(import),
         {:ok, module, resolver} <- definition(import.target, resolver),
         %{kind: :module_definition} <- module,
         [target | _] <-
           Enum.filter(
             tokens(resolver),
             &(&1.kind == :definition and &1.module == module.module and &1.name == selected.name and
                 selected.arity in &1.arities)
           ),
         {:ok, confirmed, resolver} <- definition(target, resolver),
         true <- function_identity?(confirmed, target) do
      {:ok, target, resolver}
    else
      {:error, _} = error -> error
      _ -> {:error, :elixir_rename_unresolved_import_qualifier}
    end
  end

  defp selected_definition(selected, resolver) do
    with {:ok, target, resolver} <- definition(selected, resolver) do
      case target do
        %{kind: kind} when kind in [:definition, :module_definition, :identifier] ->
          {:ok, target, resolver}

        {:external, _location} ->
          {:error, :elixir_rename_definition_outside_inventory}

        _ ->
          {:error, :elixir_rename_unresolved_symbol}
      end
    end
  end

  defp rename(%{kind: :definition, definition_form: form} = target, selected, name, resolver)
       when form in ["def", "defp"] do
    with :ok <- valid_name(name, :function),
         :ok <- authored_function_name(target.name),
         :ok <- different_name(target.name, name),
         :ok <- unique_module_owner(target, resolver),
         family = family(target, resolver),
         arities = family |> Enum.flat_map(& &1.arities) |> Enum.uniq() |> Enum.sort(),
         :ok <- compiler_destination(name, arities),
         :ok <- hazards(resolver, target, :function),
         {:ok, calls, resolver} <- function_occurrences(target, family, arities, resolver),
         :ok <- opaque_function_scopes(calls, resolver),
         {:ok, resolver} <- function_callees(calls, resolver),
         {:ok, qualifiers, resolver} <- import_occurrences(target, arities, resolver),
         occurrences = Enum.map(family ++ calls ++ qualifiers, &occurrence(&1, name)),
         :ok <- function_collisions(target, name, arities, calls, resolver),
         {:ok, resolver} <- import_collisions(target, name, calls, resolver),
         {:ok, resolver} <- existing_destination_bindings(target, name, arities, resolver),
         {:ok, resolver} <- native_destination_bindings(target, name, arities, calls, resolver) do
      owner =
        Enum.find(
          tokens(resolver),
          &(&1.kind == :module_definition and &1.module == target.module)
        )

      symbol = %{
        kind: :function,
        module: owner.module_name,
        name: target.name,
        new_name: name,
        arities: arities,
        definition: evidence(target),
        definitions: Enum.map(family, &evidence/1),
        selected: evidence(selected),
        native_caller_scopes: Enum.reverse(resolver.binding_proofs),
        caller_binding_profile:
          if(Enum.any?(calls, &local_call?/1),
            do: :elixirls_0_31_1_native_environment,
            else: :no_unqualified_callers
          )
      }

      {:ok, unique_occurrences(occurrences), symbol, resolver}
    end
  end

  defp rename(%{kind: :identifier} = target, selected, name, resolver) do
    with :ok <- valid_name(name, :variable),
         true <- target.name != "_" and Map.get(target, :attribute) == nil,
         :ok <- different_name(target.name, name),
         :ok <- hazards(resolver, target, :variable),
         candidates =
           Enum.filter(
             tokens(resolver),
             &(&1.path == target.path and &1.kind == :identifier and &1.name == target.name)
           ),
         {:ok, matches, resolver} <- matching(candidates, resolver, &same_binding?(&1, target)),
         true <- Enum.any?(matches, &(Source.key(&1) == Source.key(target))),
         {:ok, resolver} <- variable_callees(target, resolver),
         {:ok, resolver} <- variable_collision(target, name, matches, resolver) do
      symbol = %{
        kind: :variable,
        name: target.name,
        new_name: name,
        definition: evidence(target),
        selected: evidence(selected),
        binding_identity: :native_definition
      }

      {:ok, Enum.map(matches, &occurrence(&1, name)), symbol, resolver}
    else
      false -> {:error, :elixir_rename_incomplete_variable_identity}
      {:error, _} = error -> error
    end
  end

  defp rename(%{kind: :module_definition} = target, selected, name, resolver) do
    with {:ok, leaf, destination} <- module_destination(target, name),
         :ok <- different_name(target.module_name, destination),
         :ok <- unique_module_owner(target, resolver),
         :ok <- hazards(resolver, target, :module),
         :ok <- module_collisions(target, leaf, destination, resolver),
         {:ok, resolver} <- module_descendant_aliases(target, resolver),
         candidates = Enum.filter(tokens(resolver), &module_candidate?(&1, target)),
         {:ok, matches, resolver} <- matching(candidates, resolver, &same_module?(&1, target)),
         {:ok, namespace, resolver} <- module_namespace(target, destination, matches, resolver),
         {:ok, resolver} <- module_alias_scopes(matches, resolver),
         {:ok, occurrences} <- module_occurrences(matches, target, leaf, destination, resolver),
         :ok <- module_alias_collisions(occurrences, leaf, target, resolver),
         true <-
           Enum.any?(
             occurrences,
             &(&1.path == target.path and &1.start >= target.start and &1.end <= target.end)
           ) do
      symbol = %{
        kind: :module,
        name: target.module_name,
        new_name: destination,
        definition: evidence(target),
        selected: evidence(selected),
        namespace_move: false,
        explicit_alias_bindings: :preserved,
        native_namespace: namespace
      }

      {:ok, unique_occurrences(occurrences), symbol, resolver}
    else
      false -> {:error, :elixir_rename_incomplete_module_identity}
      {:error, _} = error -> error
    end
  end

  defp rename(_target, _selected, _name, _resolver), do: {:error, :elixir_rename_generated_symbol}

  defp valid_name(name, kind) do
    suffix = if kind == :function, do: "[!?]?", else: ""
    {:ok, regex} = Regex.compile("\\A[\\p{Ll}_][\\p{L}\\p{M}\\p{N}_]*" <> suffix <> "\\z", "u")

    if name != "_" and not String.starts_with?(name, "__") and name not in @reserved and
         Regex.match?(regex, name) and parsed_name?(name, kind),
       do: :ok,
       else: {:error, :elixir_rename_invalid_name}
  end

  defp parsed_name?(name, kind) do
    text = if kind == :function, do: name <> "()", else: name

    case Code.string_to_quoted(text,
           static_atoms_encoder: fn value, _meta -> {:ok, value} end,
           emit_warnings: false
         ) do
      {:ok, {identifier, _meta, arguments}} ->
        Source.word(identifier) == name and arguments == if(kind == :function, do: [], else: nil)

      _ ->
        false
    end
  end

  defp authored_function_name(name) do
    if Regex.match?(~r/\A[\p{Ll}_][\p{L}\p{M}\p{N}_]*[!?]?\z/u, name) and
         not String.starts_with?(name, "__") and name not in @reserved,
       do: :ok,
       else: {:error, :elixir_rename_function_identifier_unsupported}
  end

  defp different_name(name, name), do: {:error, :elixir_rename_unchanged_name}
  defp different_name(_old, _new), do: :ok

  defp family(target, resolver) do
    definitions =
      Enum.filter(
        tokens(resolver),
        &(&1.kind == :definition and &1.module == target.module and &1.name == target.name)
      )

    family_closure([target], definitions)
  end

  defp family_closure(family, definitions) do
    arities = family |> Enum.flat_map(& &1.arities) |> MapSet.new()

    expanded =
      Enum.filter(
        definitions,
        &Enum.any?(&1.arities, fn arity -> MapSet.member?(arities, arity) end)
      )

    if length(expanded) == length(family),
      do: expanded,
      else: family_closure(expanded, definitions)
  end

  defp function_occurrences(target, family, arities, resolver) do
    family_keys = MapSet.new(family, &Source.key/1)

    candidates =
      Enum.filter(
        tokens(resolver),
        &(&1.name == target.name and &1.kind in [:call, :identifier] and &1.arity in arities)
      )

    with {:ok, confirmed, resolver} <-
           matching(family, resolver, fn definition ->
             is_map(definition) and MapSet.member?(family_keys, Source.key(definition))
           end),
         true <- length(confirmed) == length(family),
         {:ok, matches, resolver} <-
           matching(candidates, resolver, fn definition ->
             is_map(definition) and MapSet.member?(family_keys, Source.key(definition))
           end) do
      {:ok, matches, resolver}
    else
      false -> {:error, :elixir_rename_definition_family_disagreement}
      {:error, _} = error -> error
    end
  end

  defp matching(candidates, resolver, predicate) do
    Enum.reduce_while(candidates, {:ok, [], resolver}, fn candidate, {:ok, matches, resolver} ->
      matching_candidate(candidate, matches, resolver, predicate)
    end)
    |> case do
      {:ok, matches, resolver} -> {:ok, Enum.reverse(matches), resolver}
      error -> error
    end
  end

  defp matching_candidate(candidate, matches, resolver, predicate) do
    case definition(candidate, resolver) do
      {:ok, resolved, resolver} ->
        if predicate.(resolved),
          do: {:cont, {:ok, [candidate | matches], resolver}},
          else: {:cont, {:ok, matches, resolver}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp import_occurrences(target, arities, resolver) do
    candidates =
      Enum.filter(all_imports(resolver), fn import ->
        Enum.any?(import.qualifiers, &(&1.name == target.name and &1.arity in arities))
      end)

    Enum.reduce_while(candidates, {:ok, [], resolver}, fn import, {:ok, matches, resolver} ->
      case definition(import.target, resolver) do
        {:ok, module, resolver} ->
          qualifiers = imported_qualifiers(import, module, target, arities)

          {:cont, {:ok, qualifiers ++ matches, resolver}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp imported_qualifiers(import, module, target, arities) do
    if same_module_owner?(module, target.module),
      do: Enum.filter(import.qualifiers, &(&1.name == target.name and &1.arity in arities)),
      else: []
  end

  defp compiler_destination("module_info" = name, arities) do
    case Enum.filter(arities, &(&1 in [0, 1])) do
      [] ->
        :ok

      owned ->
        {:error, {:elixir_rename_compiler_owned_destination, %{name: name, arities: owned}}}
    end
  end

  defp compiler_destination(_name, _arities), do: :ok

  defp function_collisions(target, name, arities, calls, resolver) do
    definitions = tokens(resolver)

    local =
      Enum.find(definitions, &overlapping_function_definition?(&1, target.module, name, arities))

    capture =
      Enum.find(calls, fn call ->
        local_call?(call) and
          Enum.any?(
            definitions,
            &(&1.kind == :definition and &1.module == call.module and &1.name == name and
                call.arity in &1.arities)
          )
      end)

    cond do
      local -> {:error, {:elixir_rename_destination_collision, evidence(local)}}
      capture -> {:error, {:elixir_rename_destination_capture, evidence(capture)}}
      true -> :ok
    end
  end

  defp overlapping_function_definition?(token, module, name, arities) do
    token.kind == :definition and token.module == module and token.name == name and
      Enum.any?(token.arities, &(&1 in arities))
  end

  defp import_collisions(target, name, calls, resolver) do
    imports = all_imports(resolver)

    pairs =
      for call <- calls,
          local_call?(call),
          import <- imports,
          applicable?(import, call),
          available <- [offers?(import, name, call.arity)],
          available or import.except,
          do: {import, call, available}

    Enum.reduce_while(pairs, {:ok, resolver}, fn {import, call, available}, {:ok, resolver} ->
      import_collision(import, call, available, target, name, resolver)
    end)
  end

  defp import_collision(import, call, available, target, name, resolver) do
    case definition(import.target, resolver) do
      {:ok, %{kind: :module_definition} = module, resolver} ->
        module_import_collision(module, call, available, target, name, resolver)

      {:ok, {:external, _location}, resolver} ->
        # Current native caller bindings, not the host SDK's exports, decide
        # whether an external import offers the destination in this scope.
        {:cont, {:ok, resolver}}

      {:ok, _other, _resolver} ->
        {:halt, {:error, :elixir_rename_unresolved_import}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp module_import_collision(module, call, available, target, name, resolver) do
    collision =
      Enum.any?(
        tokens(resolver),
        &public_import_destination?(&1, module.module, name, call.arity)
      )

    cond do
      not available and module.module == target.module and call.module != target.module ->
        {:halt, {:error, {:elixir_rename_destination_import_excluded, evidence(call)}}}

      collision and module.module != target.module ->
        {:halt, {:error, {:elixir_rename_destination_import_capture, evidence(call)}}}

      true ->
        {:cont, {:ok, resolver}}
    end
  end

  defp public_import_destination?(token, module, name, arity) do
    token.kind == :definition and token.module == module and token.name == name and
      arity in token.arities and token.public
  end

  defp offers?(import, name, arity) do
    member = Enum.any?(import.qualifiers, &(&1.name == name and &1.arity == arity))

    cond do
      import.only -> member
      import.except -> not member
      true -> true
    end
  end

  defp applicable?(import, call),
    do:
      import.target.path == call.path and import.target.start < call.start and
        prefix?(import.scope, call.scope)

  defp prefix?(prefix, list), do: Enum.take(list, length(prefix)) == prefix

  # Native identity corroborates spec heads, but they have no runtime caller
  # environment in which local/import/variable capture checks could apply.
  defp local_call?(%{call_form: :spec_head}), do: false
  defp local_call?(call), do: not Map.has_key?(call, :receiver)

  defp existing_destination_bindings(target, name, arities, resolver) do
    candidates =
      Enum.filter(
        tokens(resolver),
        &(&1.name == name and &1.kind in [:identifier, :call] and &1.arity in arities and
            local_call?(&1))
      )

    Enum.reduce_while(candidates, {:ok, resolver}, fn candidate, {:ok, resolver} ->
      case affected_destination_scope(target, name, candidate, resolver) do
        {:ok, true, resolver} -> existing_destination_binding(candidate, resolver)
        {:ok, false, resolver} -> {:cont, {:ok, resolver}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp existing_destination_binding(candidate, resolver) do
    case definition(candidate, resolver) do
      {:ok, %{kind: :identifier}, resolver} ->
        {:cont, {:ok, resolver}}

      {:ok, _binding, _resolver} ->
        {:halt, {:error, {:elixir_rename_existing_destination_capture, evidence(candidate)}}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp affected_destination_scope(%{module: module}, _name, %{module: module}, resolver),
    do: {:ok, true, resolver}

  defp affected_destination_scope(%{public: false}, _name, _candidate, resolver),
    do: {:ok, false, resolver}

  defp affected_destination_scope(target, name, candidate, resolver) do
    imports =
      Enum.filter(
        all_imports(resolver),
        &(applicable?(&1, candidate) and
            imports_destination?(&1, target.name, name, candidate.arity))
      )

    Enum.reduce_while(imports, {:ok, false, resolver}, fn import, {:ok, false, resolver} ->
      resolve_import_owner(import, target.module, resolver)
    end)
  end

  defp resolve_import_owner(import, owner, resolver) do
    case definition(import.target, resolver) do
      {:ok, module, resolver} ->
        if same_module_owner?(module, owner),
          do: {:halt, {:ok, true, resolver}},
          else: {:cont, {:ok, false, resolver}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp imports_destination?(import, old, name, arity) do
    old_member = Enum.any?(import.qualifiers, &(&1.name == old and &1.arity == arity))

    cond do
      import.only -> old_member
      import.except -> not old_member and offers?(import, name, arity)
      true -> true
    end
  end

  defp native_destination_bindings(target, name, arities, calls, resolver) do
    imports = all_imports(resolver)

    owner =
      Enum.find(tokens(resolver), &(&1.kind == :module_definition and &1.module == target.module))

    calls =
      calls
      |> Enum.filter(&local_call?/1)
      |> Enum.uniq_by(fn call ->
        active =
          imports |> Enum.filter(&applicable?(&1, call)) |> Enum.map(&Source.key(&1.target))

        # Parentheses force a function call; bare identifiers additionally depend
        # on variable visibility at this exact source position.
        variable_position = if call.kind == :identifier, do: call.start
        {call.path, call.function, call.scope, call.arity, active, call.kind, variable_position}
      end)

    Enum.reduce_while(calls, {:ok, resolver}, fn call, {:ok, resolver} ->
      native_destination_binding(call, owner, name, arities, resolver)
    end)
  end

  defp native_destination_binding(call, owner, name, arities, resolver) do
    caller =
      Enum.find(tokens(resolver), &(&1.kind == :module_definition and &1.module == call.module))

    function =
      Enum.find(
        tokens(resolver),
        &(&1.kind == :definition and &1.path == call.path and &1.function == call.function)
      )

    with %{module_name: owner_name} when is_binary(owner_name) <- owner,
         %{module_name: caller_name} when is_binary(caller_name) <- caller,
         %{kind: :definition} <- function,
         {:ok, info, resolver} <- native_provider(resolver),
         true <- Namespace.supported?(info),
         {:ok, uri} <- TextEdits.uri(resolver.context, call.path),
         {:ok, environment, resolver} <-
           native_request(resolver, "workspace/executeCommand", Bindings.params(uri, call)),
         {:ok, occupied, proof} <-
           Bindings.check(
             environment,
             uri,
             call,
             owner_name,
             caller_name,
             function,
             name,
             arities
           ) do
      if occupied == [] do
        proof =
          Map.merge(proof, %{
            position: evidence(call),
            old_mfa: %{module: owner_name, name: call.name, arity: call.arity},
            destination_absent: name
          })

        {:cont, {:ok, %{resolver | binding_proofs: [proof | resolver.binding_proofs]}}}
      else
        {:halt, {:error, {:elixir_rename_destination_native_binding, evidence(call), occupied}}}
      end
    else
      false -> {:halt, {:error, :elixir_rename_native_caller_binding_profile_unsupported}}
      {:error, _} = error -> {:halt, error}
      _ -> {:halt, {:error, :elixir_rename_native_caller_bindings_incomplete}}
    end
  end

  defp function_callees(calls, resolver) do
    calls
    |> Enum.filter(&local_call?/1)
    |> Enum.uniq_by(&{&1.path, &1.function})
    |> Enum.reduce_while({:ok, resolver}, fn call, {:ok, resolver} ->
      anchor =
        Enum.find(
          tokens(resolver),
          &(&1.kind == :definition and &1.path == call.path and &1.function == call.function)
        ) || call

      case variable_callees(anchor, resolver) do
        {:ok, resolver} ->
          {:cont, {:ok, resolver}}

        {:error, reason} ->
          {:halt, {:error, {:elixir_rename_unproven_caller_scope, evidence(call), reason}}}
      end
    end)
  end

  defp variable_callees(target, resolver) do
    candidates = Enum.filter(tokens(resolver), &variable_callee_candidate?(&1, target))

    Enum.reduce_while(candidates, {:ok, resolver}, fn candidate, {:ok, resolver} ->
      check_variable_callee(candidate, resolver)
    end)
  end

  defp variable_callee_candidate?(token, target) do
    token.path == target.path and token.function == target.function and
      token.kind in [:identifier, :call] and token.name != "_" and
      Map.get(token, :call_form) != :capture and
      Map.get(token, :attribute) not in [
        "spec",
        "type",
        "typep",
        "opaque",
        "callback",
        "macrocallback"
      ] and
      (prefix?(target.scope, token.scope) or prefix?(token.scope, target.scope))
  end

  defp check_variable_callee(candidate, resolver) do
    case definition(candidate, resolver) do
      {:ok, %{kind: :identifier}, resolver} ->
        {:cont, {:ok, resolver}}

      {:ok, %{kind: :definition, definition_form: form}, resolver}
      when form in ["def", "defp"] ->
        {:cont, {:ok, resolver}}

      {:ok, {:external, location}, resolver} ->
        case external_function(candidate, location, resolver) do
          {:ok, resolver} -> {:cont, {:ok, resolver}}
          {:error, _} = error -> {:halt, error}
        end

      {:ok, _opaque, _resolver} ->
        {:halt, {:error, {:elixir_rename_opaque_variable_callee, evidence(candidate)}}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp external_function(candidate, location, resolver) do
    key = {Source.key(candidate), location["uri"], location["range"]}

    if Map.has_key?(resolver.callable_cache, key) do
      {:ok, resolver}
    else
      with {:ok, info, resolver} <- native_provider(resolver),
           true <- supported_hover_provider?(info),
           {:ok, params} <- params(resolver.context, candidate),
           {:ok, hover, resolver} <- native_request(resolver, "textDocument/hover", params),
           {:ok, callable} <-
             Hover.callable(hover, candidate, Map.fetch!(resolver.inventory, candidate.path)),
           true <- callable.kind == "function" do
        {:ok, %{resolver | callable_cache: Map.put(resolver.callable_cache, key, callable)}}
      else
        false -> {:error, {:elixir_rename_opaque_variable_callee, evidence(candidate)}}
        {:error, _} = error -> error
      end
    end
  end

  defp native_provider(resolver), do: {:ok, resolver.provider_info, resolver}

  defp supported_hover_provider?(%{"name" => "ElixirLS", "version" => version})
       when is_binary(version),
       do: version == "0.31.1"

  defp supported_hover_provider?(_info), do: false

  defp variable_collision(target, name, matches, resolver) do
    candidates =
      Enum.filter(tokens(resolver), fn token ->
        token.path == target.path and token.kind == :identifier and token.name == name and
          Enum.any?(matches, &(&1.function == token.function))
      end)

    Enum.reduce_while(candidates, {:ok, resolver}, fn candidate, {:ok, resolver} ->
      check_variable_collision(candidate, target, matches, resolver)
    end)
  end

  defp check_variable_collision(candidate, target, matches, resolver) do
    case definition(candidate, resolver) do
      {:ok, binding, resolver} ->
        if variable_capture?(binding, candidate, target, matches),
          do: {:halt, {:error, {:elixir_rename_destination_capture, evidence(candidate)}}},
          else: {:cont, {:ok, resolver}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp variable_capture?(%{kind: :identifier} = binding, _candidate, _target, matches),
    do: Enum.any?(matches, &prefix?(binding.scope, &1.scope))

  defp variable_capture?(_function_or_external, candidate, target, _matches),
    do: candidate.start >= target.start and prefix?(target.scope, candidate.scope)

  defp module_destination(target, name) do
    old = String.split(target.module_name, ".")
    supplied = name |> String.trim_leading("Elixir.") |> String.split(".")

    parts =
      case supplied do
        [_leaf] -> Enum.drop(old, -1) ++ supplied
        qualified -> qualified
      end

    valid = Enum.all?(parts, &Regex.match?(~r/\A[A-Z][A-Za-z0-9_]*\z/, &1))

    cond do
      not valid ->
        {:error, :elixir_rename_invalid_module_name}

      Enum.drop(old, -1) != Enum.drop(parts, -1) ->
        {:error, :elixir_rename_module_namespace_move_unsupported}

      true ->
        {:ok, List.last(parts), Enum.join(parts, ".")}
    end
  end

  defp module_candidate?(token, _target) do
    token.kind in [:module, :module_definition, :module_self] and
      Map.get(token, :role) != :alias_name
  end

  defp module_collisions(target, _leaf, destination, resolver) do
    modules = Enum.filter(tokens(resolver), &(&1.kind == :module_definition))

    cond do
      Map.get(target, :alias_binding) != nil ->
        {:error, :elixir_rename_aliased_module_definition_unsupported}

      Enum.any?(modules, &(&1.module_name == destination)) ->
        {:error, :elixir_rename_destination_module_exists}

      Enum.any?(modules, &String.starts_with?(&1.module_name, target.module_name <> ".")) ->
        {:error, :elixir_rename_module_descendants_unsupported}

      Enum.any?(tokens(resolver), fn token ->
        token.kind in [:module, :module_definition] and
            String.starts_with?(
              String.trim_leading(token.name, "Elixir."),
              target.module_name <> "."
            )
      end) ->
        {:error, :elixir_rename_module_descendant_reference_unsupported}

      true ->
        :ok
    end
  end

  defp unique_module_owner(target, resolver) do
    modules = Enum.filter(tokens(resolver), &(&1.kind == :module_definition))
    owner = Enum.find(modules, &(&1.module == target.module))

    cond do
      is_nil(owner) ->
        {:error, :elixir_rename_function_outside_authored_module}

      Enum.count(modules, &(&1.module_name == owner.module_name)) != 1 ->
        {:error, :elixir_rename_module_redefinition_unsupported}

      opaque_module_scope?(owner, resolver) ->
        {:error, :elixir_rename_opaque_module_declaration_scope}

      true ->
        :ok
    end
  end

  defp module_descendant_aliases(target, resolver) do
    candidates =
      Enum.filter(tokens(resolver), fn token ->
        token.kind == :module and Map.get(token, :alias_binding) != nil and
          String.contains?(token.name, ".")
      end)

    Enum.reduce_while(candidates, {:ok, resolver}, fn candidate, {:ok, resolver} ->
      module_descendant_alias(candidate, target, resolver)
    end)
  end

  defp module_descendant_alias(candidate, target, resolver) do
    case definition(candidate.alias_binding.target, resolver) do
      {:ok, parent, resolver} ->
        if same_module?(parent, target),
          do: {:halt, {:error, :elixir_rename_module_descendant_reference_unsupported}},
          else: {:cont, {:ok, resolver}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp module_namespace(target, destination, matches, resolver) do
    with {:ok, info, resolver} <- native_provider(resolver),
         true <- Namespace.supported?(info),
         {:ok, available, resolver} <-
           native_request(
             resolver,
             "workspace/executeCommand",
             Namespace.availability_params(destination)
           ),
         {:ok, availability} <- Namespace.availability(available, destination),
         {:ok, anchor} <- Namespace.anchor(target, matches),
         {:ok, params} <- params(resolver.context, anchor),
         {:ok, result, resolver} <-
           native_request(
             resolver,
             "textDocument/completion",
             Map.put(params, "context", %{"triggerKind" => 1})
           ),
         {:ok, evidence} <- Namespace.check(result, target.module_name, destination) do
      {:ok, Map.put(evidence, :native_availability, availability), resolver}
    else
      false -> {:error, :elixir_rename_native_namespace_profile_unsupported}
      {:error, _} = error -> error
    end
  end

  defp module_alias_scopes(matches, resolver) do
    matches
    |> Enum.filter(
      &(Map.get(&1, :alias_binding) != nil and &1.kind == :module and
          Map.get(&1, :role) == :reference)
    )
    |> Enum.uniq_by(&{&1.path, &1.function, &1.alias_binding.target.start})
    |> Enum.reduce_while({:ok, resolver}, fn token, {:ok, resolver} ->
      module_alias_scope(token, resolver)
    end)
  end

  defp module_alias_scope(token, resolver) do
    source = Map.fetch!(resolver.inventory, token.path)

    if Enum.any?(source.hazards, &opaque_alias_rebinding?(&1, token)) do
      {:halt, {:error, {:elixir_rename_opaque_alias_binding_scope, evidence(token)}}}
    else
      case variable_callees(token, resolver) do
        {:ok, resolver} ->
          {:cont, {:ok, resolver}}

        {:error, reason} ->
          {:halt, {:error, {:elixir_rename_opaque_alias_binding_scope, evidence(token), reason}}}
      end
    end
  end

  defp opaque_alias_rebinding?(hazard, token) do
    hazard.reason in [:opaque_use, :compiler_attribute, :opaque_module_body_call] and
      prefix?(hazard.scope, token.scope) and
      (hazard.start == nil or
         (hazard.start > token.alias_binding.target.start and hazard.start < token.start))
  end

  defp opaque_module_scope?(token, resolver) do
    source = Map.fetch!(resolver.inventory, token.path)

    Enum.any?(source.hazards, fn hazard ->
      hazard.reason in [:opaque_use, :compiler_attribute, :opaque_module_body_call] and
        prefix?(hazard.scope, token.scope) and (hazard.start == nil or hazard.start < token.start)
    end)
  end

  # Qualified nested declarations do not expose a proven implicit binding here.
  defp module_alias_collisions(
         _occurrences,
         _leaf,
         %{scope: [_ | _], segments: [_, _ | _]},
         _resolver
       ),
       do: {:error, :elixir_rename_nested_module_alias_binding_unsupported}

  defp module_alias_collisions(occurrences, leaf, target, resolver) do
    edits = Map.new(occurrences, &{Source.key(&1.token), &1})

    aliases =
      tokens(resolver)
      |> Enum.filter(fn
        %{kind: :module, role: :alias_target} = token ->
          token.alias_declaration.binding == leaf or
            (not token.alias_declaration.explicit and Map.has_key?(edits, Source.key(token)))

        %{kind: :module_definition, scope: [_ | _], segments: [_]} = token ->
          module_alias_segments(token, edits) == [leaf]

        _token ->
          false
      end)
      |> Enum.sort_by(&{length(&1.scope), &1.start}, :desc)

    # Check the effective post-edit binding, including references with no edit.
    # A nested or later rebind wins; absolute names never consult this binding.
    collision =
      Enum.any?(
        tokens(resolver),
        &module_alias_capture?(&1, leaf, edits, aliases, target, resolver)
      )

    if collision, do: {:error, :elixir_rename_destination_alias_capture}, else: :ok
  end

  defp module_alias_capture?(token, leaf, edits, aliases, target, resolver) do
    if token.kind in [:module, :module_definition] and Map.get(token, :role) != :alias_name do
      case module_alias_segments(token, edits) do
        [^leaf | suffix] ->
          module_alias_rebound?(
            effective_module_alias(aliases, token),
            token,
            suffix,
            target,
            resolver
          )

        _segments ->
          false
      end
    else
      false
    end
  end

  defp module_alias_rebound?(nil, _token, _suffix, _target, _resolver), do: false

  defp module_alias_rebound?(binding, token, suffix, target, resolver),
    do: not module_alias_preserved?(binding, token, suffix, target, resolver)

  defp module_alias_segments(token, edits) do
    case Map.get(edits, Source.key(token)) do
      nil ->
        token.segments

      %{start: start, new_name: name} ->
        if start == token.start,
          do: String.split(name, "."),
          else: List.replace_at(token.segments, -1, name)
    end
  end

  defp effective_module_alias(aliases, token) do
    Enum.find(aliases, fn binding ->
      binding.path == token.path and binding.start < token.start and
        prefix?(binding.scope, token.scope)
    end)
  end

  defp module_alias_preserved?(binding, token, suffix, target, resolver) do
    original = Map.get(token, :alias_binding)

    (is_map(original) and Source.key(original.target) == Source.key(binding)) or
      unchanged_nested_module_alias?(binding, token, suffix) or
      (suffix == [] and
         same_module?(Map.get(resolver.cache, Source.key(binding)), target) and
         same_module?(Map.get(resolver.cache, Source.key(token)), target))
  end

  defp unchanged_nested_module_alias?(
         %{kind: :module_definition, segments: [name]},
         token,
         suffix
       ),
       do: match?([^name | ^suffix], token.segments)

  defp unchanged_nested_module_alias?(_binding, _token, _suffix), do: false

  defp module_occurrences(matches, target, leaf, destination, resolver) do
    old_leaf = target.module_name |> String.split(".") |> List.last()

    Enum.reduce_while(matches, {:ok, []}, fn token, {:ok, occurrences} ->
      cond do
        token.kind == :module_self ->
          {:cont, {:ok, occurrences}}

        explicit_module_alias?(token) ->
          {:cont, {:ok, occurrences}}

        absolute_module_occurrence?(token, resolver) ->
          {:cont, {:ok, [occurrence(token, "Elixir." <> destination) | occurrences]}}

        List.last(String.split(token.name, ".")) == old_leaf ->
          prefix = byte_size(token.name) - byte_size(old_leaf)

          first =
            Map.update!(
              token.range["start"],
              "character",
              &(&1 + utf16(binary_part(token.name, 0, prefix)))
            )

          range = %{
            "start" => first,
            "end" => Map.update!(first, "character", &(&1 + utf16(old_leaf)))
          }

          occurrence = %{
            path: token.path,
            start: token.start + prefix,
            end: token.end,
            range: range,
            new_name: leaf,
            token: token
          }

          {:cont, {:ok, [occurrence | occurrences]}}

        true ->
          {:halt, {:error, {:elixir_rename_module_alias_identity_unsupported, evidence(token)}}}
      end
    end)
  end

  defp explicit_module_alias?(token) do
    binding = Map.get(token, :alias_binding)
    (token.kind == :module and binding) && binding.explicit && token.name == binding.binding
  end

  defp absolute_module_occurrence?(token, resolver) do
    (token.kind == :module and Map.get(token, :role) == :reference and
       Map.get(token, :alias_binding) == nil) or
      (opaque_module_scope?(token, resolver) and
         (token.kind == :module_definition or
            Map.get(token, :role) in [:alias_target, :import_target, :require_target]))
  end

  defp opaque_function_scopes(occurrences, resolver) do
    uncertain =
      Enum.find_value(occurrences, &opaque_function_scope(&1, resolver))

    if uncertain, do: {:error, {:elixir_rename_opaque_resolution_scope, uncertain}}, else: :ok
  end

  defp opaque_function_scope(token, resolver) do
    needs_scope = not Map.has_key?(token, :receiver)
    source = Map.fetch!(resolver.inventory, token.path)

    if needs_scope do
      Enum.find_value(source.hazards, &opaque_scope_hazard(&1, token))
    end
  end

  defp opaque_scope_hazard(hazard, token) do
    if hazard.reason in [:opaque_use, :compiler_attribute, :opaque_module_body_call] and
         hazard.module in [nil, token.module],
       do: %{path: token.path, reason: hazard.reason}
  end

  defp hazards(resolver, target, kind) do
    hazard =
      Enum.find_value(resolver.inventory, fn {path, source} ->
        source_hazard(path, source.hazards, target, kind)
      end)

    if hazard, do: {:error, {:elixir_rename_semantic_uncertainty, hazard}}, else: :ok
  end

  defp source_hazard(path, hazards, target, kind) do
    Enum.find_value(hazards, fn hazard ->
      if relevant_hazard?(hazard, path, target, kind),
        do: %{path: path, reason: hazard.reason}
    end)
  end

  defp relevant_hazard?(hazard, path, target, :variable) do
    path == target.path and
      ((hazard.function == target.function and
          (target.name in hazard.names or
             hazard.reason in [:generated_code, :opaque_sigil, :lexical_introspection])) or
         (hazard.reason in [:generated_code, :quoted_code] and
            target.name in hazard.names and prefix?(target.scope, hazard.scope)) or
         (hazard.reason in [:opaque_use, :compiler_attribute, :opaque_module_body_call] and
            prefix?(hazard.scope, target.scope)))
  end

  defp relevant_hazard?(%{reason: :behaviour_contract}, _path, _target, :module), do: false

  defp relevant_hazard?(%{reason: reason} = hazard, path, target, :module)
       when reason in [:opaque_use, :opaque_module_body_call],
       do: hazard.module == nil and path == target.path

  defp relevant_hazard?(%{reason: reason} = hazard, path, target, :function)
       when reason in [
              :opaque_use,
              :compiler_attribute,
              :behaviour_contract,
              :opaque_module_body_call
            ] do
    hazard.module == target.module or (hazard.module == nil and path == target.path) or
      (hazard.reason != :opaque_module_body_call and target.name in hazard.names)
  end

  defp relevant_hazard?(hazard, _path, target, :module) do
    hazard.reason in [
      :dynamic_dispatch,
      :dynamic_module,
      :dynamic_import,
      :grouped_or_dynamic_alias,
      :generated_code,
      :opaque_sigil,
      :unsupported_module_token,
      :unsupported_import_qualifier,
      :unsupported_alias_binding
    ] or target.name in hazard.names or target.module_name in hazard.names
  end

  defp relevant_hazard?(hazard, _path, target, _kind) do
    hazard.reason in [
      :dynamic_dispatch,
      :dynamic_module,
      :dynamic_import,
      :grouped_or_dynamic_alias,
      :generated_code,
      :opaque_sigil,
      :unsupported_import_qualifier,
      :unsupported_alias_binding
    ] or target.name in hazard.names or
      (hazard.reason == :generated_definition and hazard.module == target.module)
  end

  defp definition(token, resolver) do
    key = Source.key(token)

    case Map.fetch(resolver.cache, key) do
      {:ok, definition} ->
        {:ok, definition, resolver}

      :error ->
        with {:ok, params} <- params(resolver.context, token),
             {:ok, result, resolver} <-
               native_request(resolver, "textDocument/definition", params),
             {:ok, locations, resolver} <- native_module_symbol_locations(token, result, resolver),
             true <- locations != [],
             count = resolver.locations + length(locations),
             :ok <- native_location_bound(count, resolver.limit),
             resolver = %{resolver | locations: count},
             {:ok, mapped} <- map_definitions(locations, resolver),
             {:ok, definition} <- unique_definition(mapped, resolver),
             {:ok, definition, resolver} <-
               native_signature_definition(token, definition, resolver),
             {:ok, resolver} <- verify_definition(token, definition, resolver) do
          pairs = Enum.zip(Enum.reverse(locations), mapped)

          cache =
            Enum.reduce(
              mapped,
              Map.put(resolver.cache, key, definition),
              &cache_authored_definition/2
            )

          proofs = Enum.reduce(pairs, resolver.proofs, &remember_definition_proof/2)

          {:ok, definition, %{resolver | cache: cache, proofs: proofs}}
        else
          false -> {:error, {:elixir_rename_unresolved_candidate, evidence(token)}}
          {:error, _} = error -> error
          _ -> {:error, {:elixir_rename_ambiguous_definition, evidence(token)}}
        end
    end
  end

  # ElixirLS may resolve a spec head to its whole @spec declaration, not its
  # implementation. Require that positive signature plus independently native-
  # resolved authored implementation identity; spelling alone never suffices.
  defp native_signature_definition(
         %{kind: :definition},
         %{call_form: :spec_head} = signature,
         _resolver
       ),
       do: {:error, {:elixir_rename_unproved_signature_implementation, evidence(signature)}}

  defp native_signature_definition(_token, %{call_form: :spec_head} = signature, resolver) do
    with true <- Namespace.supported?(resolver.provider_info),
         {:ok, candidate} <- signature_implementation(signature, resolver),
         {:ok, implementation, resolver} <- definition(candidate, resolver),
         {:ok, resolver} <- verify_definition(signature, implementation, resolver) do
      {:ok, implementation, resolver}
    else
      false ->
        {:error, {:elixir_rename_unproved_signature_implementation, evidence(signature)}}

      {:error, _} = error ->
        error
    end
  end

  defp native_signature_definition(_token, definition, resolver),
    do: {:ok, definition, resolver}

  defp signature_implementation(signature, resolver) do
    source = Map.fetch!(resolver.inventory, signature.path)

    case Enum.find(source.tokens, &signature_implementation?(&1, signature)) do
      nil -> {:error, {:elixir_rename_unproved_signature_implementation, evidence(signature)}}
      candidate -> {:ok, candidate}
    end
  end

  defp signature_implementation?(%{kind: :definition} = token, signature) do
    token.path == signature.path and token.module == signature.module and
      token.name == signature.name and signature.arity in token.arities and
      token.definition_form in ["def", "defp"]
  end

  defp signature_implementation?(_token, _signature), do: false

  defp cache_authored_definition(%{kind: kind} = declaration, cache)
       when kind in [:definition, :module_definition],
       do: Map.put(cache, Source.key(declaration), declaration)

  defp cache_authored_definition(_definition, cache), do: cache

  defp remember_definition_proof({location, declaration}, proofs) when is_map(declaration),
    do: Map.put_new(proofs, Source.key(declaration), location)

  defp remember_definition_proof(_external, proofs), do: proofs

  # ElixirLS has no definition at some authored nested declaration names, but
  # its project symbol index retains the canonical module and source location.
  # Only exact positive module identity is accepted; a spelling/empty query is
  # never substituted for native declaration authority.
  defp native_module_symbol_locations(%{kind: :module_definition} = token, result, resolver)
       when result in [nil, []] do
    with true <- Namespace.supported?(resolver.provider_info),
         {:ok, uri} <- TextEdits.uri(resolver.context, token.path),
         {:ok, symbols, resolver} <-
           native_request(resolver, "workspace/symbol", %{"query" => token.module_name}),
         {:ok, matches} <- native_module_symbol_matches(symbols, token, uri),
         {:ok, locations} <- locations(matches, :definition) do
      {:ok, locations, resolver}
    else
      false -> {:error, :elixir_rename_native_module_symbol_profile_unavailable}
      {:error, _} = error -> error
    end
  end

  defp native_module_symbol_locations(_token, result, resolver) do
    with {:ok, locations} <- locations(result, :definition),
         do: {:ok, locations, resolver}
  end

  defp native_module_symbol_matches(symbols, token, uri) when is_list(symbols) do
    if Enum.count_until(symbols, 1_001) <= 1_000 do
      {:ok, Enum.flat_map(symbols, &native_module_symbol_match(&1, token, uri))}
    else
      {:error, :elixir_rename_native_location_limit}
    end
  end

  defp native_module_symbol_matches(_symbols, _token, _uri),
    do: {:error, :elixir_rename_invalid_provider_result}

  defp native_module_symbol_match(
         %{
           "kind" => 2,
           "name" => actual,
           "location" => %{"uri" => uri, "range" => range} = location
         },
         token,
         uri
       )
       when is_binary(actual) do
    if String.trim_leading(actual, "Elixir.") == token.module_name and
         native_module_symbol_range?(range, token.range),
       do: [location],
       else: []
  end

  defp native_module_symbol_match(_symbol, _token, _uri), do: []

  defp native_module_symbol_range?(%{"start" => first, "end" => last}, range) do
    valid_position?(first) and valid_position?(last) and
      {first["line"], first["character"]} <= {range["start"]["line"], range["start"]["character"]} and
      {last["line"], last["character"]} >= {range["end"]["line"], range["end"]["character"]}
  end

  defp native_module_symbol_range?(_range, _token_range), do: false

  # A current buffer is necessary but does not repair a stale compiler index.
  # Corroborate authored qualifiers/import origins as well as provider positions.
  # These constraints reject contradictory identities; names never create one.
  defp verify_definition(
         %{kind: :module_definition} = token,
         %{kind: :module_definition} = declaration,
         resolver
       ) do
    if token.module_name == declaration.module_name,
      do: {:ok, resolver},
      else: {:error, {:elixir_rename_native_module_identity_mismatch, evidence(token)}}
  end

  defp verify_definition(
         %{kind: :module_self} = token,
         %{kind: :module_definition} = declaration,
         resolver
       ) do
    if token.module == declaration.module,
      do: {:ok, resolver},
      else: {:error, {:elixir_rename_native_module_identity_mismatch, evidence(token)}}
  end

  defp verify_definition(
         %{kind: :module, alias_binding: binding} = token,
         %{kind: :module_definition} = declaration,
         resolver
       )
       when is_map(binding) do
    with {:ok, parent, resolver} <- definition(binding.target, resolver) do
      expected = resolved_alias_module_name(parent, token.segments)

      if expected == declaration.module_name,
        do: {:ok, resolver},
        else: {:error, {:elixir_rename_native_module_identity_mismatch, evidence(token)}}
    end
  end

  defp verify_definition(
         %{kind: :module} = token,
         %{kind: :module_definition} = declaration,
         resolver
       ) do
    direct = String.trim_leading(token.name, "Elixir.") == declaration.module_name

    nested =
      Enum.any?(tokens(resolver), fn module ->
        module.kind == :module_definition and module.module == declaration.module and
          module.path == token.path and module.start < token.start and
          not String.contains?(module.name, ".") and module.name == token.name and
          prefix?(module.scope, token.scope)
      end)

    if direct or nested,
      do: {:ok, resolver},
      else: {:error, {:elixir_rename_native_module_identity_mismatch, evidence(token)}}
  end

  defp verify_definition(
         %{call_form: :spec_head, module: module, name: name, arity: arity} = token,
         %{kind: :definition, module: module, name: name, arities: arities},
         resolver
       ) do
    if arity in arities,
      do: {:ok, resolver},
      else: {:error, {:elixir_rename_native_callable_identity_mismatch, evidence(token)}}
  end

  defp verify_definition(%{call_form: :spec_head} = token, _declaration, _resolver),
    do: {:error, {:elixir_rename_native_callable_identity_mismatch, evidence(token)}}

  defp verify_definition(token, %{kind: :definition} = declaration, resolver) do
    cond do
      token.name != declaration.name ->
        {:error, {:elixir_rename_native_callable_identity_mismatch, evidence(token)}}

      token.kind == :definition ->
        if token.module == declaration.module,
          do: {:ok, resolver},
          else: {:error, {:elixir_rename_native_callable_identity_mismatch, evidence(token)}}

      Map.has_key?(token, :receiver) ->
        verify_receiver_origin(token, declaration, resolver)

      token.module == declaration.module ->
        {:ok, resolver}

      true ->
        verify_import_origin(token, declaration, resolver)
    end
  end

  defp verify_definition(
         %{kind: :identifier} = token,
         %{kind: :identifier} = declaration,
         resolver
       ) do
    if token.name == declaration.name and token.function == declaration.function and
         prefix?(declaration.scope, token.scope),
       do: {:ok, resolver},
       else: {:error, {:elixir_rename_native_variable_identity_mismatch, evidence(token)}}
  end

  defp verify_definition(token, %{kind: kind}, _resolver)
       when kind in [:module_definition, :identifier],
       do: {:error, {:elixir_rename_native_symbol_kind_mismatch, evidence(token)}}

  defp verify_definition(_token, _external_or_variable, resolver), do: {:ok, resolver}

  defp resolved_alias_module_name(parent, segments) when is_map(parent) do
    suffix = segments |> Enum.drop(1) |> Enum.join(".")
    if suffix == "", do: parent.module_name, else: parent.module_name <> "." <> suffix
  end

  defp resolved_alias_module_name(_parent, _segments), do: nil

  defp verify_receiver_origin(token, declaration, resolver) do
    with {:ok, receiver} <- receiver_token(token, resolver),
         {:ok, module, resolver} <- definition(receiver, resolver) do
      if same_module_owner?(module, declaration.module),
        do: {:ok, resolver},
        else: {:error, {:elixir_rename_native_callable_identity_mismatch, evidence(token)}}
    end
  end

  defp receiver_token(%{receiver: {_form, meta, _args}} = token, resolver) when is_list(meta) do
    source = Map.fetch!(resolver.inventory, token.path)

    with {:ok, start, _position} <- Source.position(source, meta[:line], meta[:column]),
         receiver when is_map(receiver) <-
           Enum.find(source.tokens, &(&1.start == start and &1.kind in [:module, :module_self])) do
      {:ok, receiver}
    else
      _ -> {:error, {:elixir_rename_unproven_callable_receiver, evidence(token)}}
    end
  end

  defp receiver_token(token, _resolver),
    do: {:error, {:elixir_rename_unproven_callable_receiver, evidence(token)}}

  defp verify_import_origin(token, declaration, resolver) do
    imports =
      Enum.filter(
        all_imports(resolver),
        &(applicable?(&1, token) and offers?(&1, token.name, token.arity))
      )

    Enum.reduce_while(imports, {:ok, false, resolver}, fn import, {:ok, false, resolver} ->
      resolve_import_owner(import, declaration.module, resolver)
    end)
    |> case do
      {:ok, true, resolver} ->
        {:ok, resolver}

      {:ok, false, _resolver} ->
        {:error, {:elixir_rename_native_import_identity_mismatch, evidence(token)}}

      {:error, _} = error ->
        error
    end
  end

  defp native_location_bound(count, limit) when count <= limit, do: :ok
  defp native_location_bound(_count, _limit), do: {:error, :elixir_rename_native_location_limit}

  defp map_definitions(locations, resolver) do
    Enum.reduce_while(locations, {:ok, []}, fn location, {:ok, definitions} ->
      case map_location(location, resolver, :definition) do
        {:ok, definition} -> {:cont, {:ok, [definition | definitions]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp unique_definition(mapped, resolver) do
    case Enum.uniq_by(mapped, &definition_key/1) do
      [definition] ->
        {:ok, definition}

      [%{kind: :definition} = first | rest] ->
        keys = MapSet.new(family(first, resolver), &Source.key/1)

        if Enum.all?(rest, &(is_map(&1) and MapSet.member?(keys, Source.key(&1)))),
          do: {:ok, first},
          else: {:error, :elixir_rename_ambiguous_native_definition}

      _ ->
        {:error, :elixir_rename_ambiguous_native_definition}
    end
  end

  defp map_location(%{"uri" => uri, "range" => range} = location, resolver, mode) do
    with :ok <- authored_uri(uri) do
      map_authored_location(uri, range, location, resolver, mode)
    end
  end

  defp authored_uri(uri) do
    parsed = URI.parse(uri)
    path = if is_binary(parsed.path), do: URI.decode(parsed.path)

    if local_file_uri?(parsed) and
         is_binary(path) and String.valid?(path) and String.starts_with?(path, "/") and
         not String.contains?(path, <<0>>) and ".." not in Path.split(path),
       do: :ok,
       else: {:error, :elixir_rename_invalid_provider_location}
  end

  defp local_file_uri?(%URI{scheme: "file", host: host, query: nil, fragment: nil})
       when host in [nil, "", "localhost"],
       do: true

  defp local_file_uri?(_uri), do: false

  defp map_authored_location(uri, range, location, resolver, mode) do
    case TextEdits.uri_path(resolver.context, uri) do
      {:ok, path} ->
        case Map.fetch(resolver.inventory, path) do
          {:ok, source} -> Source.anchored(source, range)
          :error when mode == :definition -> {:ok, {:external, location}}
          :error -> {:error, {:elixir_rename_reference_outside_inventory, path}}
        end

      {:error, _} when mode == :definition ->
        if valid_external_location?(location, resolver.context),
          do: {:ok, {:external, location}},
          else: {:error, :elixir_rename_invalid_provider_location}

      {:error, _} = error ->
        error
    end
  end

  defp valid_external_location?(
         %{"uri" => uri, "range" => %{"start" => first, "end" => last}},
         context
       ) do
    parsed = URI.parse(uri)
    path = if is_binary(parsed.path), do: URI.decode(parsed.path)

    local_file_uri?(parsed) and
      is_binary(path) and String.starts_with?(path, "/") and ".." not in Path.split(path) and
      Workspace.relative(context, path) == {:error, :outside_workspace} and
      valid_position?(first) and valid_position?(last) and
      {first["line"], first["character"]} <= {last["line"], last["character"]}
  end

  defp valid_external_location?(_location, _context), do: false

  defp definition_key({:external, location}), do: {:external, location}
  defp definition_key(definition), do: Source.key(definition)

  defp function_identity?(left, right) when is_map(left),
    do:
      left.kind == :definition and left.module == right.module and left.name == right.name and
        Enum.any?(left.arities, &(&1 in right.arities))

  defp function_identity?(_left, _right), do: false

  defp same_binding?(left, right) when is_map(left),
    do: left.kind == :identifier and Source.key(left) == Source.key(right)

  defp same_binding?(_left, _right), do: false

  defp same_module?(left, right) when is_map(left),
    do: left.kind == :module_definition and left.module == right.module

  defp same_module?(_left, _right), do: false
  defp same_module_owner?(%{kind: :module_definition, module: module}, module), do: true
  defp same_module_owner?(_left, _module), do: false

  defp corroborate(target, selected, occurrences, resolver) do
    token = if selected.kind == :import_qualifier, do: target, else: selected

    with {:ok, params} <- params(resolver.context, token),
         params = Map.put(params, "context", %{"includeDeclaration" => true}),
         {:ok, result, resolver} <- native_request(resolver, "textDocument/references", params),
         {:ok, locations} <- locations(result, :references),
         true <- locations != [],
         {:ok, resolver} <- corroborate_locations(locations, target, occurrences, resolver) do
      {:ok, length(locations), resolver}
    else
      false -> {:error, :elixir_rename_native_references_unavailable}
      {:error, _} = error -> error
    end
  end

  defp corroborate_locations(locations, target, occurrences, resolver) do
    keys = MapSet.new(occurrences, &Source.key(&1.token))

    Enum.reduce_while(locations, {:ok, resolver}, fn location, {:ok, resolver} ->
      case corroborate_location(location, target, keys, resolver) do
        {:ok, resolver} -> {:cont, {:ok, resolver}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp corroborate_location(location, target, keys, resolver) do
    case map_location(location, resolver, :reference) do
      {:ok, token} ->
        if MapSet.member?(keys, Source.key(token)) or
             retained_module_reference?(token, target, resolver),
           do: {:ok, resolver},
           else: exclude_stale_reference(token, location, target, resolver)

      {:error, _} = error ->
        error
    end
  end

  # Compiler trace references can outlive an open buffer. Every inventoried
  # document is fingerprint-attested; a current native definition must prove
  # that the authored token denotes another authored symbol. This also works
  # on apply after a preview already synchronized the buffer. Missing, external,
  # unauthored, contradictory, and still-target references remain fatal.
  defp exclude_stale_reference(token, location, target, resolver) do
    with {:ok, %{kind: kind} = current, resolver}
         when kind in [:definition, :module_definition, :identifier] <-
           definition(token, resolver),
         false <- rename_target?(current, target, resolver) do
      current_evidence =
        Map.put(
          evidence(current),
          :native_location,
          Map.get(resolver.proofs, Source.key(current))
        )

      exclusion = %{
        reason: :attested_input_now_resolves_differently,
        reference: location,
        token: evidence(token),
        current_definition: current_evidence
      }

      {:ok, %{resolver | stale_references: [exclusion | resolver.stale_references]}}
    else
      true -> {:error, :elixir_rename_reference_identity_disagreement}
      {:error, _} = error -> error
      _ -> {:error, :elixir_rename_reference_identity_disagreement}
    end
  end

  defp rename_target?(%{kind: :definition} = current, %{kind: :definition} = target, resolver),
    do: Enum.any?(family(target, resolver), &(Source.key(&1) == Source.key(current)))

  defp rename_target?(current, %{kind: :identifier} = target, _resolver),
    do: same_binding?(current, target)

  defp rename_target?(current, %{kind: :module_definition} = target, _resolver),
    do: same_module?(current, target)

  defp rename_target?(_current, _target, _resolver), do: false

  defp retained_module_reference?(
         %{kind: :module_self} = token,
         %{kind: :module_definition} = target,
         resolver
       ) do
    token.module == target.module and
      same_module?(Map.get(resolver.cache, Source.key(token)), target)
  end

  defp retained_module_reference?(
         %{kind: :module, role: :alias_name, declared_alias: descriptor},
         %{kind: :module_definition} = target,
         resolver
       ) do
    same_module?(Map.get(resolver.cache, Source.key(descriptor.target)), target)
  end

  defp retained_module_reference?(
         %{kind: :module, alias_binding: %{explicit: true, binding: binding}} = token,
         %{kind: :module_definition} = target,
         resolver
       ) do
    token.name == binding and same_module?(Map.get(resolver.cache, Source.key(token)), target)
  end

  defp retained_module_reference?(_token, _target, _resolver), do: false

  defp locations(nil, :definition), do: {:ok, []}
  defp locations(nil, :references), do: {:error, :elixir_rename_invalid_native_references}
  defp locations(%{} = location, :definition), do: locations([location], :definition)

  defp locations(list, mode) when is_list(list) do
    if Enum.count_until(list, 1_001) <= 1_000,
      do: location_entries(list, mode),
      else: {:error, :elixir_rename_invalid_provider_result}
  end

  defp locations(_result, _mode), do: {:error, :elixir_rename_invalid_provider_result}

  defp location_entries(list, mode) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"uri" => uri, "range" => %{"start" => first, "end" => last}} = location, {:ok, acc}
      when is_binary(uri) ->
        if valid_position?(first) and valid_position?(last),
          do: {:cont, {:ok, [location | acc]}},
          else: {:halt, {:error, :elixir_rename_invalid_provider_location}}

      %{"targetUri" => uri, "targetSelectionRange" => range}, {:ok, acc}
      when mode == :definition and is_binary(uri) ->
        case locations([%{"uri" => uri, "range" => range}], mode) do
          {:ok, [location]} -> {:cont, {:ok, [location | acc]}}
          error -> {:halt, error}
        end

      _location, _acc ->
        {:halt, {:error, :elixir_rename_invalid_provider_location}}
    end)
  end

  defp valid_position?(%{"line" => line, "character" => column}),
    do: is_integer(line) and line >= 0 and is_integer(column) and column >= 0

  defp valid_position?(_position), do: false

  defp native_request(%{requests: requests, limit: limit}, _method, _params)
       when requests >= limit,
       do: {:error, :elixir_rename_candidate_limit}

  defp native_request(resolver, method, params) do
    with {:ok, result} <- Stdio.request(resolver.server, method, params, resolver.timeout) do
      {:ok, result,
       %{
         resolver
         | requests: resolver.requests + 1,
           request_counts: Map.update(resolver.request_counts, method, 1, &(&1 + 1))
       }}
    end
  end

  defp params(context, token) do
    with {:ok, uri} <- TextEdits.uri(context, token.path) do
      {:ok, %{"textDocument" => %{"uri" => uri}, "position" => token.range["start"]}}
    end
  end

  defp unchanged(context, inventory, limits) do
    with {:ok, paths} <- discover(context, limits),
         true <- Enum.sort(paths) == Enum.sort(Map.keys(inventory)) do
      Enum.reduce_while(inventory, :ok, fn {path, original}, :ok ->
        unchanged_source(path, original, context, limits)
      end)
    else
      false -> {:error, :elixir_rename_inventory_changed}
      {:error, _} = error -> error
    end
  end

  defp unchanged_source(path, original, context, limits) do
    with {:ok, current} <- Files.read_bytes(context, path, max_file_bytes: limits.file_bytes),
         true <- current.snapshot == original.snapshot do
      {:cont, :ok}
    else
      false -> {:halt, {:error, {:elixir_rename_source_changed, path}}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp edit_bounds(occurrences) do
    cond do
      Enum.count_until(occurrences, 1_001) > 1_000 ->
        {:error, :lsp_edit_limit}

      occurrences |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.count_until(33) > 32 ->
        {:error, :lsp_document_limit}

      occurrences == [] ->
        {:error, :elixir_rename_no_authored_occurrences}

      true ->
        :ok
    end
  end

  defp workspace_edit(context, occurrences, versions) do
    occurrences
    |> Enum.group_by(& &1.path)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {path, occurrences}, {:ok, documents} ->
      case TextEdits.uri(context, path) do
        {:ok, uri} ->
          edits =
            occurrences
            |> Enum.sort_by(& &1.start)
            |> Enum.map(&%{"range" => &1.range, "newText" => &1.new_name})

          document = %{
            "textDocument" => %{"uri" => uri, "version" => Map.get(versions, uri)},
            "edits" => edits
          }

          {:cont, {:ok, [document | documents]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, %{"documentChanges" => Enum.reverse(documents)}}
      error -> error
    end
  end

  defp tokens(resolver), do: resolver.tokens
  defp all_imports(resolver), do: resolver.imports
  defp position(request), do: %{"line" => request.line, "character" => request.character}
  defp evidence(token), do: Map.take(token, [:path, :range, :name, :kind, :arity])

  defp occurrence(token, name),
    do: %{
      path: token.path,
      start: token.start,
      end: token.end,
      range: token.range,
      new_name: name,
      token: token
    }

  defp unique_occurrences(occurrences),
    do: Enum.uniq_by(occurrences, &{&1.path, &1.start, &1.end})

  defp utf16(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)
end
