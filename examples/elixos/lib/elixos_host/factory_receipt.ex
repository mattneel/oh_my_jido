defmodule ElixosHost.FactoryReceipt do
  @moduledoc "Verifies immutable source and target-BEAM receipts before the explicit guest scenario."

  def verify(factory \\ "/factory") do
    with {:ok, source_bytes} <- File.read(Path.join(factory, "coding/source.json")),
         {:ok, beam_bytes} <- File.read(Path.join(factory, "coding/beams.json")),
         source = :json.decode(source_bytes),
         beams = :json.decode(beam_bytes),
         true <- source["format_version"] == 1 and beams["format_version"] == 1,
         true <- sha256(source_bytes) == beams["source_receipt_sha256"],
         true <- source["source_sha256"] == beams["source_sha256"],
         true <- source_pin(source["files"]) == source["source_sha256"],
         :ok <- verify_files(Path.join(factory, "source/oh_my_jido"), source["files"]),
         :ok <- verify_files(factory, beams["files"]),
         :ok <- verify_files(factory, beams["applications"]),
         :ok <- verify_files(factory, beams["system_files"]),
         true <- source_pin(beams["system_files"]) == beams["system_source_sha256"],
         :ok <- verify_files(factory, beams["licenses"]),
         {:ok, lock} <- File.read(Path.join(factory, "source/os/mix.lock")),
         true <- sha256(lock) == beams["os_lock_sha256"],
         true <- System.version() == beams["elixir"] and beams["elixir"] == "1.20.4",
         true <- beams["otp"] == "29.1.1" and to_string(:erlang.system_info(:otp_release)) == "29",
         true <- to_string(:erlang.system_info(:version)) == beams["erts"],
         true <- to_string(:erlang.system_info(:system_architecture)) == beams["architecture"],
         :ok <- native_apps(beams["applications"]),
         :ok <- loaded_identity(factory, beams["files"]) do
      {:ok,
       Map.take(beams, [
         "source_sha256",
         "system_source_sha256",
         "elixir",
         "otp",
         "erts",
         "architecture",
         "os_lock_sha256"
       ])}
    else
      false -> {:error, :factory_identity_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_factory_receipt}
  end

  defp source_pin(files) do
    files
    |> Enum.sort_by(& &1["path"])
    |> Enum.map(&"#{&1["sha256"]}  #{&1["path"]}\n")
    |> IO.iodata_to_binary()
    |> sha256()
  end

  defp verify_files(root, files) when is_list(files) and files != [] do
    Enum.reduce_while(files, :ok, fn entry, :ok ->
      relative = entry["path"]

      with true <-
             is_binary(relative) and Path.type(relative) == :relative and
               ".." not in Path.split(relative),
           {:ok, bytes} <- File.read(Path.join(root, relative)),
           true <- sha256(bytes) == entry["sha256"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, {:factory_file_mismatch, relative}}}
      end
    end)
  end

  defp verify_files(_root, _files), do: {:error, :empty_factory_inventory}

  defp native_apps(apps) do
    required = ~w(oh_my_jido elixos_host jido jido_ai req_llm)

    if Enum.all?(required, fn app -> Enum.count(apps, &(&1["app"] == app)) == 1 end) and
         not Enum.any?(apps, &(&1["app"] in ~w(quickbeam snakepit snakebridge))) do
      :ok
    else
      {:error, :invalid_native_application_closure}
    end
  end

  defp loaded_identity(factory, files) do
    modules = [
      OhMyJido.Runtime,
      ElixosHost.Host,
      ElixosHost.Candidate,
      ElixosHost.T10,
      Elixos.Candidate,
      Elixos.Candidate.Child,
      Elixos.Candidate.Runner,
      Elixos.Health,
      Elixos.Boot.AutoCommit,
      Jido.AgentServer,
      Jido.AgentServer.PrivateDiagnostics,
      ReqLLM.Streaming.Failure
    ]

    Enum.reduce_while(modules, :ok, fn module, :ok ->
      with {:module, ^module} <- Code.ensure_loaded(module),
           {^module, bytes, filename} <- :code.get_object_code(module),
           relative = Path.relative_to(to_string(filename), factory),
           %{"sha256" => digest} <- Enum.find(files, &(&1["path"] == relative)),
           true <- sha256(bytes) == digest,
           {:ok, [{^module, md5}]} <- :beam_lib.md5(bytes),
           ^md5 <- module.module_info(:md5) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, {:factory_loaded_code_mismatch, module}}}
      end
    end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
