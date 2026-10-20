defmodule OhMyJidoDocs.Candidates.Dependencies do
  @moduledoc false

  alias OhMyJidoDocs.Candidates.Runner

  # The project and dependency Mix files are evaluated only in this disposable VM.
  # The length-framed result contains strings, never executable terms or host atoms.
  @probe """
  Mix.start()
  defmodule Mix.Tasks.Docs.CandidateDependencies do
    use Mix.Task

    @impl true
    def run(_arguments) do
      Mix.Task.run("loadconfig", [])
      paths =
        Mix.Dep.load_and_cache()
        |> Enum.map(fn dependency ->
          destination = dependency.opts[:dest] || dependency.opts[:path]
          if not is_binary(destination), do: raise("dependency has no source destination")
          Path.expand(destination)
        end)
        |> Enum.uniq()
        |> Enum.sort()
      if length(paths) > 2_048, do: raise("dependency count exceeds the offline preflight bound")
      frame = fn value -> [<<byte_size(value)::unsigned-big-32>>, value] end
      metadata = [to_string(:erlang.system_info(:system_architecture)), to_string(:erlang.system_info(:nif_version)) | paths]
      File.write!(System.fetch_env!("DOCS_DEPENDENCY_PATHS"), ["DCP2", Enum.map(metadata, frame)])
    end
  end
  Mix.CLI.main(["docs.candidate_dependencies"])
  """

  def check(context, env, owner, cancel_ref, callbacks, timeout_ms, child_env) do
    driver = Path.join(context["root"], "dependency-probe.exs")
    metadata = Path.join(context["root"], "dependency-paths-#{env}.bin")

    with {:ok, elixir} <- Runner.available(setting(:elixir_executable, "elixir")),
         :ok <- File.write(driver, @probe) do
      receipt =
        Runner.run(elixir, [driver],
          cwd: context["app"],
          env: Map.put(child_env, "DOCS_DEPENDENCY_PATHS", metadata),
          timeout_ms: timeout_ms,
          max_output_bytes: setting(:candidate_output_limit, 131_072),
          cancel_ref: cancel_ref,
          owner_pid: owner,
          before_start: callbacks.before_start,
          on_start: fn process ->
            callbacks.on_start.(Map.put(process, "phase", "dependency_preflight"))
          end,
          on_scope: fn process ->
            callbacks.on_scope.(Map.put(process, "phase", "dependency_preflight"))
          end
        )
        |> Map.merge(%{"phase" => "dependency_preflight", "mix_env" => env})

      complete_preflight(receipt, metadata, context)
    else
      {:error, reason} ->
        unavailable(
          %{
            "phase" => "dependency_preflight",
            "mix_env" => env,
            "cleanup" => %{"status" => "not_started"}
          },
          reason
        )
    end
  end

  defp complete_preflight(
         %{"status" => "passed", "effect" => "completed"} = receipt,
         metadata,
         context
       ) do
    case inspect_dependencies(metadata, context) do
      {:ok, artifacts, paths} ->
        Map.merge(receipt, %{"native_artifacts" => artifacts, "dependency_paths" => paths})

      {:error, reason} ->
        unavailable(receipt, reason)
    end
  end

  defp complete_preflight(%{"status" => "passed"} = receipt, _metadata, _context) do
    Map.merge(receipt, %{"status" => "uncertain", "reason" => "child_cleanup_unconfirmed"})
  end

  defp complete_preflight(receipt, _metadata, _context), do: receipt

  defp inspect_dependencies(metadata, context) do
    with {:ok, %{type: :regular, size: size}} when size <= 1_048_576 <- File.lstat(metadata),
         {:ok, <<"DCP2", framed::binary>>} <- File.read(metadata),
         {:ok, [architecture, nif | paths]} <- frames(framed, [], 0),
         true <- Enum.all?(paths, &confined_dependency?(&1, context)),
         {:ok, artifacts} <- inspect_paths(paths, architecture, nif, context) do
      {:ok, artifacts, paths}
    else
      false -> {:error, :external_dependency_path}
      {:error, _} = error -> error
      _ -> {:error, :invalid_dependency_probe}
    end
  end

  defp frames(<<>>, values, _count), do: {:ok, Enum.reverse(values)}

  defp frames(<<length::unsigned-big-32, rest::binary>>, values, count)
       when length > 0 and length <= 4_096 and count < 2_050 and byte_size(rest) >= length do
    <<value::binary-size(^length), rest::binary>> = rest

    if String.valid?(value),
      do: frames(rest, [value | values], count + 1),
      else: {:error, :invalid_dependency_probe}
  end

  defp frames(_, _, _), do: {:error, :invalid_dependency_probe}

  defp confined_dependency?(path, context) do
    Path.type(path) == :absolute and Path.expand(path) == path and
      Enum.any?([context["source"], context["deps"]], fn root ->
        path == root or String.starts_with?(path, root <> "/")
      end)
  end

  defp inspect_paths(paths, architecture, nif, context) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, artifacts} ->
      with {:ok, names} <- File.ls(path),
           manifests = Enum.filter(names, &checksum_manifest?/1),
           {:ok, found} <- inspect_manifests(path, manifests, architecture, nif, context) do
        {:cont, {:ok, artifacts ++ found}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp checksum_manifest?("checksum.exs"), do: true

  defp checksum_manifest?(name),
    do: String.starts_with?(name, "checksum-") and String.ends_with?(name, ".exs")

  defp inspect_manifests(root, manifests, architecture, nif, context) do
    Enum.reduce_while(manifests, {:ok, []}, fn name, {:ok, artifacts} ->
      file = Path.join(root, name)
      cache = if name == "checksum.exs", do: context["make_cache"], else: context["rustler_cache"]

      with {:ok, entries} <- checksum_entries(file),
           {:ok, names} <-
             required_artifacts(Path.basename(root) <> "/" <> name, entries, architecture, nif),
           {:ok, found} <- verify_artifacts(cache, names, entries, file) do
        {:cont, {:ok, artifacts ++ found}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp checksum_entries(path) do
    with {:ok, %{type: :regular, size: size}} when size <= 1_048_576 <- File.lstat(path),
         {:ok, content} <- File.read(path),
         {:ok, {:%{}, _meta, entries}} <-
           Code.string_to_quoted(content, existing_atoms_only: true),
         true <-
           Enum.all?(entries, fn
             {name, "sha256:" <> hash} when is_binary(name) ->
               Path.basename(name) == name and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

             _ ->
               false
           end) do
      {:ok, Map.new(entries, fn {name, "sha256:" <> hash} -> {name, hash} end)}
    else
      _ -> {:error, {:unsupported_native_checksum_manifest, Path.basename(path)}}
    end
  end

  defp required_artifacts(manifest, entries, architecture, nif) do
    cpu = architecture |> String.split("-") |> hd()
    abi = if String.contains?(architecture, "musl"), do: "musl", else: "gnu"
    child_nif = version_tuple(nif)

    compatible = Enum.filter(Map.keys(entries), &compatible_artifact?(&1, cpu, abi, child_nif))

    selected = Map.new(setting(:candidate_native_artifacts, %{}))[manifest]

    case compatible do
      [] -> {:error, {:native_artifact_target_unavailable, manifest, architecture, nif}}
      _ -> select_artifacts(manifest, compatible, selected)
    end
  end

  defp compatible_artifact?(name, cpu, abi, child_nif) do
    nif = artifact_nif(name)

    String.contains?(name, cpu <> "-") and
      (String.contains?(name, "-linux-" <> abi <> "-") or
         String.contains?(name, "-linux-" <> abi <> ".") or
         String.contains?(name, "-linux-" <> abi <> "--")) and
      nif != nil and nif <= child_nif
  end

  defp select_artifacts(manifest, compatible, selected)
       when is_list(selected) and selected != [] do
    if Enum.all?(selected, &(&1 in compatible)),
      do: {:ok, selected},
      else: {:error, {:invalid_native_artifact_selection, manifest}}
  end

  defp select_artifacts(manifest, _compatible, selected) when not is_nil(selected) do
    {:error, {:invalid_native_artifact_selection, manifest}}
  end

  defp select_artifacts(manifest, compatible, nil) do
    highest = compatible |> Enum.map(&artifact_nif/1) |> Enum.max()

    defaults =
      Enum.filter(
        compatible,
        &(artifact_nif(&1) == highest and not String.contains?(&1, "--"))
      )

    case defaults do
      [name] -> {:ok, [name]}
      _ -> {:error, {:native_artifact_selection_required, manifest, compatible}}
    end
  end

  defp artifact_nif(name) do
    case Regex.run(~r/-nif-(\d+)\.(\d+)-/, name, capture: :all_but_first) do
      [major, minor] -> {String.to_integer(major), String.to_integer(minor)}
      _ -> nil
    end
  end

  defp version_tuple(version) do
    case String.split(version, ".") do
      [major, minor | _] -> {String.to_integer(major), String.to_integer(minor)}
      _ -> {0, 0}
    end
  end

  defp verify_artifacts(cache, names, entries, manifest) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, artifacts} ->
      path = Path.join(cache, name)

      with {:ok, %{type: :regular, size: size}} when size <= 268_435_456 <- File.lstat(path),
           {:ok, hash} <- sha256_file(path),
           true <- hash == entries[name] do
        artifact = %{
          "file" => name,
          "cache_path" => path,
          "sha256" => hash,
          "bytes" => size,
          "checksum_manifest" => manifest
        }

        {:cont, {:ok, [artifact | artifacts]}}
      else
        false -> {:halt, {:error, {:native_artifact_checksum_mismatch, name}}}
        _ -> {:halt, {:error, {:native_artifact_unavailable, name}}}
      end
    end)
  end

  defp sha256_file(path) do
    hash =
      path
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, hash}
  rescue
    File.Error -> {:error, :native_artifact_unreadable}
  end

  defp unavailable(receipt, reason) do
    reason = inspect(reason, limit: 30, printable_limit: 2_048)

    Map.merge(receipt, %{
      "status" => "unavailable",
      "reason" => reason,
      "output" => (receipt["output"] || "") <> "\nOffline dependency preflight: " <> reason
    })
  end

  defp setting(key, default), do: Application.get_env(:oh_my_jido_docs, key, default)
end
