defmodule OhMyJidoDocs.Candidates.Execution do
  @moduledoc false

  alias OhMyJidoDocs.Candidates.{Dependencies, Runner, Source}

  @default_steps [
    {"test", ["deps.compile"]},
    {"test", ["compile", "--warnings-as-errors"]},
    {"test", ["test", "--exclude", "candidate_integration"]},
    {"prod", ["deps.compile"]},
    {"prod", ["compile", "--warnings-as-errors"]},
    {"prod", ["assets.deploy"]},
    {"prod", ["release", "--overwrite"]}
  ]
  @offline_proxy_keys [
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "NO_PROXY",
    "no_proxy"
  ]

  def check_available do
    with {:ok, _mix} <- Runner.available(setting(:mix_executable, "mix")),
         {:ok, _elixir} <- Runner.available(setting(:elixir_executable, "elixir")),
         {:ok, steps} <- check_steps(),
         :ok <- asset_tools_available(steps) do
      process_tools_available()
    end
  end

  def check(candidate, owner, cancel_ref, callbacks) do
    started = System.monotonic_time(:millisecond)
    deadline = started + setting(:candidate_check_timeout_ms, 600_000)

    with {:ok, mix} <- Runner.available(setting(:mix_executable, "mix")),
         {:ok, steps} <- check_steps(),
         :ok <- asset_tools_available(steps),
         {:ok, context} <- stage(candidate, "check"),
         {:ok, receipts} <-
           run_steps(
             with_preflights(steps),
             mix,
             context,
             owner,
             cancel_ref,
             callbacks,
             deadline,
             []
           ) do
      receipt = %{
        "status" => "passed",
        "digest" => candidate.digest,
        "context" => context,
        "steps" => receipts,
        "output" => combined_output(receipts),
        "duration_ms" => System.monotonic_time(:millisecond) - started
      }

      with :ok <- verify_context(candidate, context),
           {:ok, release} <- release_path(context) do
        Map.put(receipt, "release", release)
      else
        {:error, reason} ->
          Map.merge(receipt, %{
            "status" => "failed",
            "reason" => reason_text(reason),
            "output" => receipt["output"] <> "\n" <> reason_text(reason)
          })
      end
    else
      {:stopped, receipts, context} ->
        last = List.last(receipts)

        %{
          "status" => last["status"],
          "digest" => candidate.digest,
          "context" => context,
          "steps" => receipts,
          "output" => combined_output(receipts),
          "duration_ms" => System.monotonic_time(:millisecond) - started
        }

      {:error, reason} ->
        %{
          "status" => "unavailable",
          "cleanup" => %{"status" => "not_started"},
          "digest" => candidate.digest,
          "reason" => reason_text(reason),
          "output" => reason_text(reason),
          "duration_ms" => System.monotonic_time(:millisecond) - started
        }
    end
  end

  def preview_spec(candidate) do
    context = candidate.check_receipt["context"]
    release = candidate.check_receipt["release"]

    with true <- is_map(context) and is_binary(release),
         :ok <- confined_context(candidate, context),
         :ok <- verify_context(candidate, context),
         {:ok, ^release} <- release_path(context),
         {:ok, port} <- reserve_port(),
         {:ok, preview_root} <- fresh_directory(context["root"], "preview") do
      env =
        environment(context, "prod")
        |> Map.merge(%{
          "DOCS_PREVIEW" => "1",
          "DOCS_EDITOR_ENABLED" => "0",
          "DOCS_CHILD" => "preview",
          "DOCS_DATA_DIR" => preview_root,
          "DOCS_SOURCE_ROOT" => context["source"],
          "DOCS_PUBLISHED_ROOT" => Path.join([context["app"], "priv", "docs"]),
          "DATABASE_PATH" => Path.join(preview_root, "preview.sqlite3"),
          "POOL_SIZE" => "1",
          "PHX_SERVER" => "true",
          "PHX_HOST" => "localhost",
          "PORT" => Integer.to_string(port),
          "SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(64)),
          "RELEASE_DISTRIBUTION" => "none"
        })

      {:ok,
       %{
         executable: release,
         args: ["start"],
         cwd: context["app"],
         env: env,
         port: port,
         url: "http://127.0.0.1:#{port}/",
         context: context,
         preview_root: preview_root
       }}
    else
      false -> {:error, :release_unavailable}
      {:error, _} = error -> error
    end
  end

  def deployment_available(candidate) do
    with {:ok, _executable} <- deployment_executable(),
         {:ok, app} <- required_setting(:fly_app),
         true <- Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, app),
         {:ok, _token} <- required_setting(:fly_token),
         :ok <- process_tools_available(),
         {:ok, _dockerfile} <-
           context_file(
             %{"source" => candidate.source_path},
             setting(:fly_dockerfile, "examples/docs_site/Dockerfile")
           ),
         {:ok, _config} <-
           context_file(
             %{"source" => candidate.source_path},
             setting(:fly_config, "examples/docs_site/fly.toml")
           ) do
      :ok
    else
      false -> {:error, :invalid_fly_app}
      {:error, _} = error -> error
    end
  end

  def deployment_spec(candidate) do
    with {:ok, executable} <- deployment_executable(),
         {:ok, app} <- required_setting(:fly_app),
         true <- Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, app),
         {:ok, token} <- required_setting(:fly_token),
         {:ok, context} <- stage(candidate, "deploy", dependencies: false),
         {:ok, dockerfile} <-
           context_file(context, setting(:fly_dockerfile, "examples/docs_site/Dockerfile")),
         {:ok, config} <-
           context_file(context, setting(:fly_config, "examples/docs_site/fly.toml")),
         :ok <- verify_context(candidate, context),
         :ok <- Source.read_only(context["source"], candidate.manifest) do
      context = Map.put(context, "readonly", true)

      {:ok,
       %{
         executable: executable,
         args: [
           "deploy",
           context["source"],
           "--app",
           app,
           "--config",
           config,
           "--dockerfile",
           dockerfile,
           "--remote-only",
           "--yes"
         ],
         cwd: context["source"],
         env:
           environment(context, "prod")
           |> Map.drop(@offline_proxy_keys)
           |> Map.put("FLY_API_TOKEN", token),
         redactions: [token],
         context: context,
         app: app
       }}
    else
      false -> {:error, :invalid_fly_app}
      {:error, _} = error -> error
    end
  end

  def verify_context(candidate, context) do
    with :ok <- confined_context(candidate, context),
         true <- Source.digest(candidate.manifest) == candidate.digest,
         :ok <-
           Source.verify(context["source"], candidate.manifest,
             readonly: Map.get(context, "readonly", false)
           ) do
      :ok
    else
      false -> {:error, :execution_source_changed}
      {:error, _} = error -> error
    end
  end

  def ready?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 250) do
      {:ok, socket} ->
        try do
          with :ok <-
                 :gen_tcp.send(
                   socket,
                   "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                 ),
               {:ok, <<"HTTP/1.", _version, " ", code::binary-size(3), _rest::binary>>} <-
                 :gen_tcp.recv(socket, 0, 250),
               {status, ""} <- Integer.parse(code) do
            status in 200..299
          else
            _ -> false
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        false
    end
  end

  def environment(context, env) do
    %{
      "PATH" =>
        setting(:candidate_path, System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"),
      "LANG" => "C.UTF-8",
      "HOME" => context["home"],
      "TMPDIR" => context["tmp"],
      "MIX_HOME" => context["mix_home"],
      "HEX_HOME" => context["hex_home"],
      "HEX_OFFLINE" => "1",
      "HTTP_PROXY" => "http://127.0.0.1:0",
      "HTTPS_PROXY" => "http://127.0.0.1:0",
      "ALL_PROXY" => "http://127.0.0.1:0",
      "NO_PROXY" => "127.0.0.1,localhost,::1",
      "http_proxy" => "http://127.0.0.1:0",
      "https_proxy" => "http://127.0.0.1:0",
      "all_proxy" => "http://127.0.0.1:0",
      "no_proxy" => "127.0.0.1,localhost,::1",
      "CARGO_NET_OFFLINE" => "true",
      "CARGO_HOME" => Path.join(context["home"], ".cargo"),
      "RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH" => context["rustler_cache"],
      "ELIXIR_MAKE_CACHE_DIR" => context["make_cache"],
      "MIX_ENV" => env,
      "MIX_DEPS_PATH" => context["deps"],
      "MIX_BUILD_PATH" => Path.join([context["root"], "build", env]),
      "DOCS_CANDIDATE_PYTHON" => setting(:candidate_python_executable, "python3"),
      "DOCS_CHILD" => "check",
      "DOCS_DATA_DIR" => Path.join(context["root"], "data"),
      "DATABASE_PATH" => Path.join([context["root"], "data", "check.sqlite3"]),
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CEILING_DIRECTORIES" => context["root"],
      "GIT_ALLOW_PROTOCOL" => "",
      "GIT_ASKPASS" => "/bin/false",
      "GIT_SSH_COMMAND" => "/bin/false",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_OPTIONAL_LOCKS" => "0",
      "ERL_FLAGS" => setting(:candidate_erl_flags, "+S 2:2 +SDcpu 1 +SDio 1")
    }
    |> Map.merge(toolchain_environment())
  end

  def execution_root(candidate, kind, attempt_id) when kind in ["check", "deploy"] do
    Path.join([data_dir(), "candidate-effects", candidate.id, kind <> "-" <> attempt_id])
  end

  defp stage(candidate, kind, opts \\ []) do
    with :ok <- Source.verify(candidate.source_path, candidate.manifest, readonly: true),
         {:ok, root} <- attempt_directory(candidate, kind) do
      case stage_source(candidate, root, opts) do
        {:ok, _context} = result ->
          result

        {:error, reason} ->
          cleanup = Source.remove_tree(root)

          {:error,
           {:staging_failed, reason,
            %{
              "root" => root,
              "cleanup_status" => if(cleanup == :ok, do: "removed", else: "uncertain"),
              "cleanup_error" => if(cleanup == :ok, do: nil, else: reason_text(cleanup))
            }}}
      end
    end
  end

  defp stage_source(candidate, root, opts) do
    source = Path.join(root, "source")

    with :ok <- Source.copy(candidate.source_path, source, candidate.manifest),
         context = %{
           "root" => root,
           "source" => source,
           "app" => Path.join(source, candidate.app_relative),
           "deps" => Path.join([source, candidate.app_relative, "deps"]),
           "home" => Path.join(root, "home"),
           "tmp" => Path.join(root, "tmp"),
           "mix_home" => Path.join(root, "mix-home"),
           "hex_home" => Path.join(root, "hex-home"),
           "rustler_cache" => Path.join(root, "rustler-cache"),
           "make_cache" => Path.join(root, "make-cache"),
           "source_files" => map_size(candidate.manifest),
           "source_bytes" =>
             Enum.reduce(candidate.manifest, 0, fn {_path, entry}, total ->
               total + entry["size"]
             end)
         },
         :ok <- create_private_directories(context),
         :ok <- stage_toolchain(context, opts),
         {:ok, dependency_digest} <- stage_dependencies(candidate, context, opts),
         context = Map.put(context, "dependency_digest", dependency_digest),
         :ok <- verify_context(candidate, context) do
      {:ok, context}
    end
  end

  defp attempt_directory(candidate, kind) do
    receipt = if kind == "check", do: candidate.check_receipt, else: candidate.deployment_receipt

    with {:ok, attempt_id} <- Ecto.UUID.cast(receipt["attempt_id"]),
         root = execution_root(candidate, kind, attempt_id),
         :ok <- File.mkdir_p(Path.dirname(root)),
         :ok <- File.mkdir(root),
         :ok <- File.chmod(root, 0o700) do
      {:ok, root}
    else
      :error -> {:error, :invalid_execution_attempt}
      {:error, _} = error -> error
    end
  end

  defp create_private_directories(context) do
    Enum.reduce_while(
      ["deps", "home", "tmp", "mix_home", "hex_home", "rustler_cache", "make_cache"],
      :ok,
      fn key, :ok ->
        case File.mkdir_p(context[key]) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:private_directory, reason}}}
        end
      end
    )
  end

  defp stage_dependencies(_candidate, _context, dependencies: false), do: {:ok, nil}

  defp stage_dependencies(candidate, context, _opts) do
    trusted_source = setting(:source_root, candidate.source_root)

    roots =
      setting(:candidate_dependency_roots, [
        Path.join([trusted_source, candidate.app_relative, "deps"]),
        Path.join(trusted_source, "deps")
      ])

    with true <- is_list(roots) and Enum.all?(roots, &is_binary/1),
         :ok <- copy_dependency_roots(roots, context["deps"]),
         {:ok, manifest} <-
           Source.manifest(context["deps"],
             max_files: setting(:candidate_dependency_file_limit, 200_000),
             max_entries: 2 * setting(:candidate_dependency_file_limit, 200_000),
             max_directories: setting(:candidate_dependency_file_limit, 200_000),
             max_bytes: setting(:candidate_dependency_byte_limit, 1_073_741_824)
           ) do
      {:ok, Source.digest(manifest)}
    else
      false -> {:error, :invalid_dependency_roots}
      {:error, _} = error -> error
    end
  end

  defp copy_dependency_roots(roots, target) do
    result =
      Enum.reduce_while(roots, {:ok, %{files: 0, bytes: 0}}, fn root, {:ok, budget} ->
        continue_copy(copy_dependency_root(root, target, budget))
      end)

    case result do
      {:ok, _budget} -> :ok
      error -> error
    end
  end

  defp copy_dependency_root(root, target, budget) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, budget}, fn name, {:ok, budget} ->
          copy_dependency_name(root, target, name, budget)
        end)

      {:error, :enoent} ->
        {:ok, budget}

      {:error, reason} ->
        {:error, {:dependency_source, reason}}
    end
  end

  defp copy_dependency_name(root, target, name, budget) do
    destination = Path.join(target, name)

    if Source.excluded?(name) or File.exists?(destination) do
      {:cont, {:ok, budget}}
    else
      continue_copy(copy_dependency_package(Path.join(root, name), destination, budget))
    end
  end

  defp continue_copy({:ok, _budget} = result), do: {:cont, result}
  defp continue_copy(error), do: {:halt, error}

  defp copy_dependency_package(source, destination, budget) do
    with true <- budget.files < setting(:candidate_dependency_file_limit, 200_000),
         true <- budget.bytes < setting(:candidate_dependency_byte_limit, 1_073_741_824),
         {:ok, manifest} <-
           Source.manifest(source,
             max_files: setting(:candidate_dependency_file_limit, 200_000) - budget.files,
             max_entries: 2 * setting(:candidate_dependency_file_limit, 200_000),
             max_directories: setting(:candidate_dependency_file_limit, 200_000),
             max_bytes: setting(:candidate_dependency_byte_limit, 1_073_741_824) - budget.bytes,
             max_file_bytes: setting(:candidate_dependency_max_file_bytes, 67_108_864)
           ),
         budget = %{
           budget
           | files: budget.files + map_size(manifest),
             bytes:
               budget.bytes +
                 Enum.reduce(manifest, 0, fn {_path, entry}, total -> total + entry["size"] end)
         },
         true <- budget.files <= setting(:candidate_dependency_file_limit, 200_000),
         true <- budget.bytes <= setting(:candidate_dependency_byte_limit, 1_073_741_824),
         :ok <- Source.copy(source, destination, manifest) do
      Enum.reduce_while([".hex", ".git"], {:ok, budget}, fn name, {:ok, budget} ->
        copy_dependency_metadata(source, destination, name, budget)
      end)
    else
      false -> {:error, :dependency_size_limit}
      {:error, _} = error -> error
    end
  end

  defp copy_dependency_metadata(source, destination, name, budget) do
    path = Path.join(source, name)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:cont, {:ok, budget}}

      {:error, reason} ->
        {:halt, {:error, reason}}

      {:ok, _stat} ->
        continue_copy(copy_cache(path, Path.join(destination, name), 0, budget))
    end
  end

  defp copy_cache(source, target, depth, budget) do
    cond do
      depth > 32 ->
        {:error, :dependency_depth_limit}

      Source.excluded?(Path.basename(source)) and
        Path.basename(source) not in [".git", ".hex"] and
          not (Map.get(budget, :toolchain, false) and Path.extname(source) == ".beam") ->
        {:ok, budget}

      true ->
        copy_cache_entry(source, target, depth, budget)
    end
  end

  defp copy_cache_entry(source, target, depth, budget) do
    with {:ok, stat} <- File.lstat(source) do
      case {stat.type, Path.basename(source)} do
        {:regular, ".git"} ->
          {:error, :unsafe_dependency_git_metadata}

        {:regular, _name} ->
          copy_cache_file(source, target, stat, budget)

        {:directory, _name} ->
          copy_cache_directory(source, target, depth, budget)

        _ ->
          {:error, :unsafe_dependency_entry}
      end
    end
  end

  defp copy_cache_file(source, target, stat, budget) do
    budget = %{budget | files: budget.files + 1, bytes: budget.bytes + stat.size}

    with true <- budget.files <= setting(:candidate_dependency_file_limit, 200_000),
         true <- budget.bytes <= setting(:candidate_dependency_byte_limit, 1_073_741_824),
         :ok <- validate_cached_pem(source),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.cp(source, target),
         :ok <- File.chmod(target, Bitwise.band(stat.mode, 0o777)) do
      {:ok, budget}
    else
      false -> {:error, :dependency_size_limit}
      {:error, _} = error -> error
    end
  end

  defp copy_cache_directory(source, target, depth, budget) do
    with :ok <- File.mkdir_p(target),
         {:ok, names} <- File.ls(source),
         names = cache_names(source, names),
         {:ok, budget} <- copy_cache_children(names, source, target, depth, budget),
         :ok <- write_cached_git_config(source, target) do
      {:ok, budget}
    end
  end

  defp cache_names(source, names) do
    cond do
      Path.basename(source) == ".git" ->
        Enum.filter(
          names,
          &(&1 in ["HEAD", "objects", "refs", "packed-refs", "shallow", "index"])
        )

      Path.basename(source) == "objects" and Path.basename(Path.dirname(source)) == ".git" ->
        names -- ["info"]

      true ->
        names
    end
  end

  defp copy_cache_children(names, source, target, depth, budget) do
    Enum.reduce_while(names, {:ok, budget}, fn name, {:ok, budget} ->
      continue_copy(
        copy_cache(Path.join(source, name), Path.join(target, name), depth + 1, budget)
      )
    end)
  end

  defp write_cached_git_config(source, target) do
    if Path.basename(source) == ".git" do
      with :ok <-
             File.write(
               Path.join(target, "config"),
               "[core]\nrepositoryformatversion = 0\nbare = false\n"
             ),
           {:ok, origin, status} <-
             Source.git(
               Path.dirname(source),
               ["config", "--local", "--no-includes", "--get", "remote.origin.url"],
               8_192
             ) do
        write_cached_git_origin(target, String.trim(origin), status)
      end
    else
      :ok
    end
  end

  defp write_cached_git_origin(_target, "", 1), do: :ok

  defp write_cached_git_origin(target, origin, 0) do
    uri = URI.parse(origin)

    if uri.userinfo == nil or
         (uri.scheme == "ssh" and not String.contains?(uri.userinfo, ":")) do
      case Source.git(
             Path.dirname(target),
             ["config", "--local", "remote.origin.url", origin],
             8_192
           ) do
        {:ok, _, 0} -> :ok
        {:ok, _, _} -> {:error, :dependency_git_metadata_failed}
        error -> error
      end
    else
      {:error, :unsafe_dependency_git_origin}
    end
  end

  defp write_cached_git_origin(_target, _origin, _status),
    do: {:error, :dependency_git_metadata_failed}

  defp validate_cached_pem(source) do
    if String.downcase(Path.extname(source)) == ".pem" do
      case Source.manifest(Path.dirname(source), paths: [Path.basename(source)], max_files: 1) do
        {:ok, _manifest} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp stage_toolchain(_context, dependencies: false), do: :ok

  defp stage_toolchain(context, _opts) do
    home =
      setting(
        :candidate_mix_home,
        System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")
      )

    native = Map.new(setting(:candidate_native_caches, []))

    sources = [
      {Path.join(home, "archives"), Path.join(context["mix_home"], "archives"), true},
      {native[:rustler], context["rustler_cache"], false},
      {native[:elixir_make], context["make_cache"], false}
    ]

    result =
      Enum.reduce_while(
        sources,
        {:ok, %{files: 0, bytes: 0, toolchain: false}},
        &copy_toolchain_source/2
      )

    case result do
      {:ok, _budget} -> :ok
      error -> error
    end
  end

  defp copy_toolchain_source({nil, _destination, _toolchain}, {:ok, budget}) do
    {:cont, {:ok, budget}}
  end

  defp copy_toolchain_source({source, destination, toolchain}, {:ok, budget}) do
    cond do
      File.exists?(source) ->
        continue_copy(copy_cache(source, destination, 0, %{budget | toolchain: toolchain}))

      toolchain ->
        {:cont, {:ok, budget}}

      true ->
        {:halt, {:error, :native_cache_unavailable}}
    end
  end

  defp with_preflights(steps) do
    {pipeline, _seen} =
      Enum.reduce(steps, {[], MapSet.new()}, fn {env, _args} = step, {pipeline, seen} ->
        if MapSet.member?(seen, env) do
          {[step | pipeline], seen}
        else
          {[step, {env, :dependency_preflight} | pipeline], MapSet.put(seen, env)}
        end
      end)

    Enum.reverse(pipeline)
  end

  defp run_steps([], _mix, _context, _owner, _cancel, _notify, _deadline, receipts),
    do: {:ok, Enum.reverse(receipts)}

  defp run_steps(
         [{env, :dependency_preflight} | rest],
         mix,
         context,
         owner,
         cancel,
         callbacks,
         deadline,
         receipts
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cancelled =
      receive do
        {:cancel, ^cancel} -> true
      after
        0 -> false
      end

    receipt =
      if remaining > 0 and Process.alive?(owner) and not cancelled do
        Dependencies.check(
          context,
          env,
          owner,
          cancel,
          callbacks,
          remaining,
          environment(context, env)
        )
      else
        %{
          "status" => if(remaining <= 0, do: "timed_out", else: "cancelled"),
          "phase" => "dependency_preflight",
          "mix_env" => env,
          "output" => "Stopped before dependency preflight.",
          "cleanup" => %{"status" => "not_started", "scope" => "current_step"}
        }
      end

    if receipt["status"] == "passed" do
      run_steps(rest, mix, context, owner, cancel, callbacks, deadline, [receipt | receipts])
    else
      {:stopped, Enum.reverse([receipt | receipts]), context}
    end
  end

  defp run_steps([{env, args} | rest], mix, context, owner, cancel, callbacks, deadline, receipts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cancelled =
      receive do
        {:cancel, ^cancel} -> true
      after
        0 -> false
      end

    if remaining > 0 and Process.alive?(owner) and not cancelled do
      receipt =
        Runner.run(mix, args,
          cwd: context["app"],
          env: environment(context, env),
          timeout_ms: remaining,
          max_output_bytes: setting(:candidate_output_limit, 131_072),
          cancel_ref: cancel,
          owner_pid: owner,
          before_start: callbacks.before_start,
          on_start: fn process -> callbacks.on_start.(Map.put(process, "mix_env", env)) end,
          on_scope: fn process -> callbacks.on_scope.(Map.put(process, "mix_env", env)) end
        )
        |> Map.put("mix_env", env)
        |> confirm_step_cleanup()

      if receipt["status"] == "passed" do
        run_steps(rest, mix, context, owner, cancel, callbacks, deadline, [receipt | receipts])
      else
        {:stopped, Enum.reverse([receipt | receipts]), context}
      end
    else
      receipt = %{
        "status" => if(remaining <= 0, do: "timed_out", else: "cancelled"),
        "output" => "Child pipeline stopped before starting another process.",
        "cleanup" => %{"status" => "not_started", "scope" => "current_step"},
        "args" => args,
        "mix_env" => env
      }

      {:stopped, Enum.reverse([receipt | receipts]), context}
    end
  end

  defp confirm_step_cleanup(receipt) do
    if receipt["status"] == "passed" and receipt["effect"] != "completed" do
      Map.merge(receipt, %{"status" => "uncertain", "reason" => "child_cleanup_unconfirmed"})
    else
      receipt
    end
  end

  defp check_steps do
    steps = setting(:candidate_check_steps, @default_steps)

    if is_list(steps) and steps != [] and Enum.count_until(steps, 17) <= 16 and
         Enum.all?(steps, &valid_check_step?/1) do
      {:ok, steps}
    else
      {:error, :invalid_check_steps}
    end
  end

  defp valid_check_step?({env, [_ | _] = args}) when env in ["test", "prod"] do
    Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>)))
  end

  defp valid_check_step?(_step), do: false

  defp asset_tools_available(steps) do
    if Enum.any?(steps, fn {_env, args} -> hd(args) == "assets.deploy" end) do
      Enum.reduce_while(["TAILWIND_PATH", "ESBUILD_PATH"], :ok, fn key, :ok ->
        asset_tool_available(key)
      end)
    else
      :ok
    end
  end

  defp asset_tool_available(key) do
    with path when is_binary(path) <- toolchain_environment()[key],
         {:ok, _} <- Runner.available(path) do
      {:cont, :ok}
    else
      _ -> {:halt, {:error, {:asset_tool_unavailable, key}}}
    end
  end

  defp toolchain_environment do
    allowed = ["TAILWIND_PATH", "ESBUILD_PATH", "MIX_REBAR3", "CC", "CXX", "MAKE"]

    assets =
      setting(:candidate_asset_tools, [])
      |> Enum.reduce(%{}, fn
        {:tailwind, path}, acc when is_binary(path) -> Map.put(acc, "TAILWIND_PATH", path)
        {:esbuild, path}, acc when is_binary(path) -> Map.put(acc, "ESBUILD_PATH", path)
        _, acc -> acc
      end)

    setting(:candidate_toolchain_env, %{})
    |> Map.new()
    |> Map.take(allowed)
    |> Map.merge(assets)
  end

  defp release_path(context) do
    name = setting(:candidate_release_name, "oh_my_jido_docs")

    if is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name) do
      path = Path.join([context["root"], "build", "prod", "rel", name, "bin", name])

      case Runner.available(path) do
        {:ok, ^path} -> {:ok, path}
        _ -> {:error, :release_unavailable}
      end
    else
      {:error, :invalid_release_name}
    end
  end

  defp confined_context(candidate, %{
         "root" => root,
         "source" => source,
         "app" => app,
         "deps" => deps
       }) do
    prefix = Path.join([data_dir(), "candidate-effects", candidate.id]) <> "/"

    if String.starts_with?(Path.expand(root), prefix) and
         source == Path.join(root, "source") and
         app == Path.join(source, candidate.app_relative) and
         deps == Path.join(app, "deps") do
      :ok
    else
      {:error, :invalid_execution_context}
    end
  end

  defp confined_context(_, _), do: {:error, :invalid_execution_context}

  defp context_file(context, relative) do
    root = context["source"]
    path = Path.expand(relative, root)

    with true <- is_binary(relative) and Path.type(relative) == :relative,
         true <- String.starts_with?(path, root <> "/"),
         {:ok, %{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> {:error, :deployment_context_file_unavailable}
    end
  end

  defp process_tools_available do
    Enum.reduce_while(
      [
        {:setsid_executable, "setsid"},
        {:candidate_python_executable, "python3"},
        {:kill_executable, "kill"}
      ],
      :ok,
      fn {key, default}, :ok ->
        case Runner.available(setting(key, default)) do
          {:ok, _} -> {:cont, :ok}
          _ -> {:halt, {:error, :process_supervision_unavailable}}
        end
      end
    )
  end

  defp deployment_executable do
    case setting(:flyctl, nil) do
      path when is_binary(path) -> Runner.available(path)
      _ -> {:error, :deployment_unconfigured}
    end
  end

  defp required_setting(key) do
    case setting(key, nil) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :deployment_unconfigured}
    end
  end

  defp reserve_port do
    with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]),
         {:ok, {_ip, port}} <- :inet.sockname(socket) do
      :gen_tcp.close(socket)
      {:ok, port}
    end
  end

  defp fresh_directory(parent, kind) do
    path = Path.join(parent, kind <> "-" <> Ecto.UUID.generate())

    with :ok <- File.mkdir_p(parent), :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    end
  end

  defp combined_output(receipts) do
    limit = setting(:candidate_output_limit, 131_072)

    receipts
    |> Enum.map_join("\n", fn receipt ->
      executable = Path.basename(receipt["executable"] || "mix")

      "$ MIX_ENV=#{receipt["mix_env"]} #{executable} #{Enum.join(receipt["args"] || [], " ")}\n#{receipt["output"] || ""}"
    end)
    |> bounded_utf8(limit)
  end

  defp bounded_utf8(output, limit) do
    prefix = binary_part(output, 0, min(byte_size(output), limit))
    if String.valid?(prefix), do: prefix, else: bounded_utf8(prefix, byte_size(prefix) - 1)
  end

  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 1_024)
  defp setting(key, default), do: Application.get_env(:oh_my_jido_docs, key, default)

  defp data_dir do
    source = Path.expand(setting(:source_root, Path.expand("../../../../..", __DIR__)))
    Path.expand(setting(:data_dir, Path.join(source, "var/docs_site")), source)
  end
end
