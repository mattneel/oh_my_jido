defmodule OhMyJido.Install do
  @moduledoc """
  Source-checkout dependency setup using native Igniter plans and previews.

  Bootstrap from the consumer directory before resolving its dependencies:

      elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
      elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes

  Add `--snakepit` to both commands only when Python Eval is wanted. The bootstrap
  may fetch its pinned Igniter tooling on first use; it never fetches consumer
  dependencies, compiles the consumer, reads credentials, or starts its services.

  Mix overrides are not transitive: the consumer must declare the patched Jido
  and ReqLLM paths at its own dependency root. This installer adds those paths
  and exact Jido.AI/Jido.Action 2.4.0 requirements without copying or modifying
  the checkout's patched snapshots. Existing incompatible declarations are
  refused rather than replaced. A literal `project/0` result using `deps: deps()`
  and a literal private `deps/0` list are required; computed layouts are refused.

  Only `mix.exs` is changed. The standalone `elixir` bootstrap does not evaluate
  the target Mix project, formatter files, Igniter config, or application config.
  This implementation never cross-loads or evaluates those target files itself.
  A direct `mix oh_my_jido.install` invocation still performs Mix's normal target
  project and configuration loading before dispatching this task; it does not
  carry the standalone bootstrap's no-evaluation guarantee. Runtime supervision,
  host bindings, permissions, credentials, and Python prerequisites remain
  explicit host responsibilities.
  """

  # Delay this native declaration so the standalone bootstrap does not need the
  # optional development boundary compiler or expand its macro when absent.
  if Code.ensure_loaded?(Boundary) do
    Code.eval_quoted(
      quote do
        use Boundary, top_level?: true, deps: [Mix]
      end,
      [],
      __ENV__
    )
  end

  if Code.ensure_loaded?(Igniter) do
    alias Sourceror.Zipper

    @doc "Creates an empty native plan without evaluating target configuration."
    @spec new() :: Igniter.t()
    def new do
      struct!(Igniter, rewrite: Rewrite.new(dot_formatter: Rewrite.DotFormatter.default()))
      |> Igniter.assign(:igniter_exs, dont_move_files: ["mix.exs"], source_folders: [])
    end

    @doc """
    Adds dependency changes to a native Igniter plan, without writing any files.

    Options are `:source` (required checkout directory) and `:snakepit` (boolean,
    default `false`). Validation and conflicts become native Igniter issues, so
    applying an invalid plan cannot partially install its other dependencies.
    """
    @spec plan(Igniter.t(), keyword()) :: Igniter.t()
    def plan(igniter, opts) do
      with :ok <- validate_options(opts, [:source, :snakepit]),
           {:ok, source} <- source_directory(opts),
           :ok <- validate_snapshots(source, Keyword.get(opts, :snakepit, false)) do
        dependencies = dependencies(source, Keyword.get(opts, :snakepit, false))
        update_dependencies(igniter, dependencies)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    rescue
      error in [SyntaxError, TokenMissingError, File.Error] ->
        Igniter.add_issue(igniter, "Cannot safely read mix.exs (#{inspect(error.__struct__)}).")
    end

    @doc """
    Previews setup, applying only with both `--apply` and `--yes`.

    The default is a true dry-run. `default_source` is supplied by the checkout
    bootstrap; direct task callers must supply `--source`. No tasks are queued,
    so dependency fetching and compilation remain a separate user operation.
    """
    @spec run([String.t()], String.t() | nil) :: {:ok, atom()} | {:error, String.t()}
    def run(argv, default_source \\ nil) do
      with {:ok, opts} <- parse_options(argv, default_source) do
        igniter = plan(new(), Keyword.take(opts, [:source, :snakepit]))

        Mix.shell().info("""
        OhMyJido source setup: #{Keyword.fetch!(opts, :source)}
        Planned scope: mix.exs dependencies only; patched Jido 2.4.0 and ReqLLM 1.28.0,
        Jido.AI/Jido.Action == 2.4.0#{if opts[:snakepit], do: ", patched Snakepit 0.14.0 (runtime: false)", else: "; no Snakepit"}.
        No consumer credentials, provider requests, consumer dependency fetch, or consumer service startup.
        """)

        # Native :yes suppresses diff output as well as prompts. Render its
        # actual plain diff explicitly while keeping dry-run noninteractive.
        Mix.shell().info(Igniter.diff(Rewrite.sources(igniter.rewrite), color?: false))

        case Igniter.do_or_dry_run(igniter,
               dry_run: true,
               yes: true,
               title: "OhMyJido source setup preview"
             ) do
          :issues ->
            {:error, "Source setup refused; resolve the reported issues and preview again."}

          preview when preview in [:dry_run_with_changes, :dry_run_with_no_changes] ->
            apply_preview(igniter, opts[:apply], preview)
        end
      end
    end

    defp apply_preview(igniter, true, _preview) do
      case Application.ensure_all_started(:rewrite) do
        {:ok, _started} -> write_plan(igniter)
        {:error, _reason} -> {:error, "Cannot start native Rewrite installer tooling."}
      end
    end

    defp apply_preview(_igniter, _apply, preview), do: {:ok, preview}

    defp write_plan(igniter) do
      case Igniter.do_or_dry_run(igniter, yes: true) do
        :issues -> {:error, "Source setup could not write the planned change."}
        result -> {:ok, result}
      end
    end

    defp parse_options(argv, default_source) do
      {opts, positional, invalid} =
        OptionParser.parse(argv,
          strict: [
            source: [:string, :keep],
            snakepit: [:boolean, :keep],
            apply: [:boolean, :keep],
            dry_run: [:boolean, :keep],
            yes: [:boolean, :keep]
          ]
        )

      opts =
        if Keyword.has_key?(opts, :source),
          do: opts,
          else: Keyword.put(opts, :source, default_source)

      cond do
        invalid != [] or positional != [] ->
          {:error,
           "Use --source PATH, --dry-run, optional --snakepit, or --apply --yes; unknown arguments are refused."}

        duplicate_keys?(opts) ->
          {:error, "Repeated setup options are refused."}

        true ->
          validate_apply_options(opts)
      end
    end

    defp validate_apply_options(opts) do
      cond do
        opts[:apply] == true and opts[:dry_run] == true ->
          {:error, "--apply and --dry-run cannot be combined."}

        opts[:apply] == true and opts[:yes] != true ->
          {:error, "--apply requires --yes after reviewing the dry-run preview."}

        opts[:yes] == true and opts[:apply] != true ->
          {:error, "--yes is only valid with --apply; it cannot opt a preview into changes."}

        true ->
          with {:ok, source} <- source_directory(opts),
               do: {:ok, Keyword.put(opts, :source, source)}
      end
    end

    defp validate_options(opts, supported) do
      cond do
        not Keyword.keyword?(opts) ->
          {:error, "Setup options must be a keyword list."}

        duplicate_keys?(opts) ->
          {:error, "Repeated setup options are refused."}

        Enum.any?(Keyword.keys(opts), &(&1 not in supported)) ->
          {:error, "Supported setup options are :source and :snakepit."}

        not is_boolean(Keyword.get(opts, :snakepit, false)) ->
          {:error, ":snakepit must be an explicit boolean."}

        true ->
          :ok
      end
    end

    defp duplicate_keys?(opts),
      do: length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts)))

    defp source_directory(opts) do
      case Keyword.get(opts, :source) do
        source when is_binary(source) and byte_size(source) > 0 ->
          source = Path.expand(source)

          if File.regular?(Path.join(source, "mix.exs")) do
            {:ok, source}
          else
            {:error, "--source must point to an existing OhMyJido checkout containing mix.exs."}
          end

        _ ->
          {:error, "An explicit OhMyJido checkout is required: --source /absolute/oh_my_jido."}
      end
    end

    defp validate_snapshots(source, snakepit?) do
      snapshots = [{:jido, "2.4.0"}, {:req_llm, "1.28.0"}]
      snapshots = if snakepit?, do: snapshots ++ [{:snakepit, "0.14.0"}], else: snapshots

      Enum.reduce_while(snapshots, :ok, fn {app, version}, :ok ->
        root = Path.join([source, "vendor", Atom.to_string(app)])

        with true <- File.regular?(Path.join(root, "mix.exs")),
             {:ok, content} <- File.read(Path.join(root, "UPSTREAM.json")),
             {:ok, manifest} <- Jason.decode(content),
             %{"package" => package, "version" => ^version, "privacy_boundary_updates" => updates}
             when is_map(updates) <- manifest,
             true <- package == Atom.to_string(app) do
          {:cont, :ok}
        else
          _ ->
            {:halt,
             {:error,
              "The selected checkout must contain its patched #{app} #{version} snapshot and UPSTREAM.json provenance in #{root}; Hex replacements are not supported."}}
        end
      end)
    end

    defp dependencies(source, snakepit?) do
      dependencies = [
        {:oh_my_jido, path: source},
        {:jido, path: Path.join(source, "vendor/jido"), override: true},
        {:req_llm, path: Path.join(source, "vendor/req_llm"), override: true},
        {:jido_ai, "== 2.4.0"},
        {:jido_action, "== 2.4.0"}
      ]

      if snakepit? do
        dependencies ++
          [
            {:snakepit,
             path: Path.join(source, "vendor/snakepit"), override: true, runtime: false}
          ]
      else
        dependencies
      end
    end

    defp update_dependencies(igniter, dependencies) do
      # Igniter's high-level dependency updater evaluates existing declarations,
      # and its automatic formatting evaluates target config. Use its native
      # zipper codemods with Rewrite's explicit default formatter instead.
      igniter = Igniter.include_existing_file(igniter, "mix.exs", required?: true, format?: false)

      if igniter.issues == [] do
        source = Rewrite.source!(igniter.rewrite, "mix.exs")

        with {:ok, zipper} <- deps_location(Rewrite.Source.get(source, :quoted)),
             {:ok, missing} <- missing_dependencies(zipper, dependencies) do
          zipper =
            Enum.reduce(missing, zipper, &append_dependency/2)

          Igniter.update_file(
            igniter,
            "mix.exs",
            &Rewrite.Source.update(&1, :quoted, Zipper.topmost_root(zipper),
              dot_formatter: Rewrite.DotFormatter.default()
            ),
            format?: false
          )
        else
          {:error, message} -> Igniter.add_issue(igniter, message)
        end
      else
        igniter
      end
    end

    defp append_dependency(dependency, zipper) do
      {:ok, zipper} =
        Igniter.Code.List.append_to_list(zipper, Sourceror.parse_string!(inspect(dependency)))

      zipper
    end

    defp deps_location(quoted) do
      with [module_node] <- Enum.filter(statements(quoted), &project_module?/1),
           module <- Zipper.find(Zipper.zip(quoted), &(&1 == module_node)),
           {:ok, project} <- function_location(module, :def, :project),
           :ok <- validate_project(unblock(Zipper.node(project))),
           {:ok, deps} <- function_location(module, :defp, :deps),
           deps <- unwrap_zipper(deps),
           true <- is_list(Zipper.node(deps)) do
        {:ok, deps}
      else
        {:error, _} = error ->
          error

        _ ->
          {:error,
           "Setup requires a Mix.Project with a literal project/0 keyword result using deps: deps() and a literal private deps/0 list. Refactor computed dependency layouts explicitly before retrying."}
      end
    end

    # Never use environment-aware alias/function discovery here. Native Igniter
    # discovery can expand authored macros even when the eventual plan is dry-run.
    defp statements({:__block__, _, nodes}), do: nodes
    defp statements(node), do: [node]

    defp module_body({:defmodule, _, [_name, options]}) when is_list(options),
      do: keyword_node(options, :do)

    defp module_body(_node), do: :error

    defp project_module?(node) do
      case module_body(node) do
        {:ok, body} -> Enum.any?(statements(body), &literal_mix_use?/1)
        :error -> false
      end
    end

    defp literal_mix_use?({:use, _, [{:__aliases__, _, [:Mix, :Project]}]}), do: true
    defp literal_mix_use?(_node), do: false

    defp function_location(module, kind, name) do
      {:ok, body} = module_body(Zipper.node(module))

      case Enum.filter(statements(body), &function_definition?(&1, kind, name)) do
        [definition] ->
          zipper = Zipper.find(module, &(&1 == definition))

          {:ok,
           zipper
           |> Zipper.down()
           |> Zipper.right()
           |> Zipper.down()
           |> Zipper.down()
           |> Zipper.right()}

        _ ->
          :error
      end
    end

    defp function_definition?({kind, _, [{name, _, args}, [_entry] = options]}, kind, name)
         when args in [[], nil],
         do: match?({:ok, _}, keyword_node(options, :do))

    defp function_definition?(_node, _kind, _name), do: false

    defp unwrap_zipper(zipper) do
      case Zipper.node(zipper) do
        {:__block__, _, [_value]} -> unwrap_zipper(Zipper.down(zipper))
        _ -> zipper
      end
    end

    defp validate_project(project) when is_list(project) do
      cond do
        keyword_node(project, :apps_path) != :missing ->
          {:error, "Run source setup in an individual Mix application, not an umbrella root."}

        literal_keyword(project, :app) == {:ok, :oh_my_jido} ->
          {:error, "Run source setup in the consumer project, not the OhMyJido checkout itself."}

        match?({:ok, {:deps, _, args}} when args in [[], nil], keyword_node(project, :deps)) ->
          :ok

        true ->
          {:error,
           "project/0 must use deps: deps(); setup will not modify an unused deps/0 helper."}
      end
    end

    defp validate_project(_),
      do: {:error, "project/0 must return a literal keyword list for safe source setup."}

    defp keyword_node(list, key) do
      Enum.find_value(list, :missing, fn
        {key_node, value} -> if literal(key_node) == {:ok, key}, do: {:ok, unblock(value)}
        _ -> nil
      end)
    end

    defp literal_keyword(list, key) do
      case keyword_node(list, key) do
        {:ok, node} -> literal(node)
        :missing -> :error
      end
    end

    defp missing_dependencies(zipper, dependencies) do
      names = Enum.map(dependencies, &elem(&1, 0))

      with {:ok, existing} <- existing_dependencies(Zipper.node(zipper), names) do
        Enum.reduce_while(dependencies, {:ok, []}, &missing_dependency(&1, &2, existing))
      end
    end

    defp missing_dependency(dependency, {:ok, missing}, existing) do
      name = elem(dependency, 0)

      case Map.fetch(existing, name) do
        :error -> {:cont, {:ok, missing ++ [dependency]}}
        {:ok, node} -> existing_dependency(node, dependency, missing)
      end
    end

    defp existing_dependency(node, dependency, missing) do
      with {:ok, current} <- literal(node),
           true <- normalize_dependency(current) == normalize_dependency(dependency) do
        {:cont, {:ok, missing}}
      else
        _ -> {:halt, dependency_conflict(elem(dependency, 0), dependency)}
      end
    end

    defp existing_dependencies(nodes, names) do
      Enum.reduce_while(nodes, {:ok, %{}}, fn node, {:ok, existing} ->
        case dependency_name(unblock(node)) do
          {:ok, name} when is_atom(name) ->
            collect_dependency(name, node, names, existing)

          _ ->
            {:halt,
             {:error,
              "deps/0 must contain named dependency tuples, not computed entries; setup cannot safely determine their overrides."}}
        end
      end)
    end

    defp dependency_name({:{}, _, [name | _values]}), do: literal(name)
    defp dependency_name({name, _value}), do: literal(name)
    defp dependency_name(_node), do: :error

    defp collect_dependency(name, node, names, existing) do
      cond do
        name not in names ->
          {:cont, {:ok, existing}}

        Map.has_key?(existing, name) ->
          {:halt,
           {:error,
            "Dependency #{inspect(name)} appears more than once; resolve the duplicate before source setup."}}

        true ->
          {:cont, {:ok, Map.put(existing, name, node)}}
      end
    end

    defp dependency_conflict(name, desired) do
      {:error,
       "Existing dependency #{inspect(name)} conflicts with the selected source checkout or exact pin. Keep your selection, or explicitly change it to #{inspect(desired)} and preview again. Setup never replaces existing declarations."}
    end

    defp normalize_dependency({app, opts}) when is_list(opts),
      do: {app, nil, normalize_dependency_options(opts)}

    defp normalize_dependency({app, requirement}) when is_binary(requirement),
      do: {app, normalize_requirement(requirement), []}

    defp normalize_dependency({app, requirement, opts}) when is_list(opts),
      do: {app, normalize_requirement(requirement), normalize_dependency_options(opts)}

    defp normalize_dependency(other), do: other

    defp normalize_requirement(requirement) when is_binary(requirement) do
      exact = requirement |> String.trim() |> String.trim_leading("==") |> String.trim()

      case Version.parse(exact) do
        {:ok, version} -> {:exact, version}
        :error -> requirement
      end
    end

    defp normalize_requirement(other), do: other

    defp normalize_dependency_options(opts) do
      if Keyword.keyword?(opts) do
        opts
        |> Enum.map(fn
          {:path, path} when is_binary(path) -> {:path, Path.expand(path)}
          option -> option
        end)
        |> Enum.sort()
      else
        opts
      end
    end

    defp unblock({:__block__, _, [value]}), do: unblock(value)
    defp unblock(value), do: value

    defp literal({:__block__, _, [value]}), do: literal(value)
    defp literal({:{}, _, values}), do: literal_sequence(values, &List.to_tuple/1)
    defp literal({left, right}), do: literal_sequence([left, right], &List.to_tuple/1)
    defp literal(values) when is_list(values), do: literal_sequence(values, & &1)

    defp literal(value) when is_atom(value) or is_binary(value) or is_number(value),
      do: {:ok, value}

    defp literal(_), do: :error

    defp literal_sequence(values, finish) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
        case literal(value) do
          {:ok, value} -> {:cont, {:ok, [value | decoded]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, finish.(Enum.reverse(decoded))}
        :error -> :error
      end
    end
  else
    @unavailable """
    OhMyJido installation requires optional Igniter tooling.
    Bootstrap before resolving the consumer graph with:

        elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
        elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes

    For an already-resolved project, add {:igniter, "== 0.8.4", only: [:dev, :test], runtime: false}
    to that project's dependencies and invoke mix oh_my_jido.install --source /absolute/oh_my_jido.
    """

    @doc false
    def new, do: raise(ArgumentError, @unavailable)

    @doc false
    def plan(_igniter, _opts), do: raise(ArgumentError, @unavailable)

    @doc false
    def run(_argv, _default_source \\ nil), do: {:error, @unavailable}
  end
end
