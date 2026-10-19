defmodule OhMyJido.Eval.Python do
  @moduledoc """
  Persistent Python Eval through exclusively leased Snakepit-managed workers.

  The exact worker PID and Python process token are pinned for the generation;
  affinity metadata expiry or Snakepit's automatic worker replacement cannot
  silently create an empty namespace. A host must start Snakepit's gRPC runtime
  prerequisites explicitly. This module never installs a Python environment.
  """
  @behaviour OhMyJido.Eval.Backend

  if Code.ensure_loaded?(Snakepit.GRPCWorker) do
    alias OhMyJido.Eval.Bridge
    alias Snakepit.Bridge.{SessionStore, ToolRegistry}
    alias Snakepit.Pool.Registry, as: WorkerRegistry
    alias Snakepit.Pool.WorkerSupervisor

    @impl true
    def open(context, opts) do
      with :ok <- private_diagnostics(),
           :ok <- isolation(opts),
           :ok <- prerequisites() do
        id = "omj_eval_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        control_token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        generation = Keyword.fetch!(opts, :generation)
        bridge = Keyword.fetch!(opts, :bridge)
        boot_timeout = Keyword.get(opts, :boot_timeout, 30_000)

        handle = %{
          worker_id: id,
          session_id: nil,
          owner: id,
          worker: nil,
          token: nil,
          generation: generation,
          control_token: control_token,
          context: context,
          opts: opts
        }

        try do
          with :ok <- Bridge.track_python(bridge, id),
               {:ok, worker} <-
                 WorkerSupervisor.start_worker(
                   id,
                   Snakepit.GRPCWorker,
                   Snakepit.Adapters.GRPCPython,
                   bridge,
                   worker_config(opts, id, control_token)
                 ),
               {:ok, session_id} <- Snakepit.GRPCWorker.get_session_id(worker),
               :ok <- Bridge.track_python(bridge, id, session_id),
               handle = %{handle | worker: worker, session_id: session_id},
               :ok <- SessionStore.store_worker_session(session_id, id),
               :ok <- register_bridge(session_id, bridge, generation, opts),
               {:ok, %{"worker_token" => token, "generation" => ^generation}} <-
                 command(handle, "open", %{workspace: context.workspace}, boot_timeout) do
            {:ok, %{handle | token: token}}
          else
            {:error, reason} ->
              cleanup(handle)
              {:error, {:backend_unavailable, :python, reason}}

            other ->
              cleanup(handle)
              {:error, {:backend_unavailable, :python, {:invalid_handshake, other}}}
          end
        rescue
          exception ->
            cleanup(handle)
            {:error, {:backend_unavailable, :python, Exception.message(exception)}}
        catch
          :exit, reason ->
            cleanup(handle)
            {:error, {:backend_unavailable, :python, reason}}
        end
      end
    rescue
      exception -> {:error, {:backend_unavailable, :python, Exception.message(exception)}}
    catch
      :exit, reason -> {:error, {:backend_unavailable, :python, reason}}
    end

    @impl true
    def execute(handle, request) do
      with :ok <- same_worker(handle),
           {:ok, result} <-
             command(
               handle,
               "execute",
               %{
                 source: request.source,
                 execution_id: request.id,
                 timeout: request.timeout,
                 output_limit: request.output_limit,
                 callback_timeout: Keyword.get(handle.opts, :callback_timeout, 2_000)
               },
               request.timeout + 500
             ),
           :ok <- same_identity(handle, result),
           {:ok, status} <- status(result["status"]) do
        {:ok,
         %{
           status: status,
           display: Map.get(result, "display", ""),
           diagnostics: Map.get(result, "diagnostics", []),
           error: Map.get(result, "error"),
           truncated: Map.get(result, "truncated", false)
         }}
      end
    catch
      :exit, reason -> {:error, {:python_worker_lost, reason}}
    end

    @impl true
    def interrupt(handle, _execution_id), do: cleanup(handle)

    @impl true
    def reset(handle) do
      with :ok <- close(handle) do
        open(handle.context, Keyword.put(handle.opts, :generation, handle.generation + 1))
      end
    end

    @impl true
    def close(handle) do
      if same_worker(handle) == :ok do
        try do
          command(handle, "close", %{}, 1_000)
        catch
          :exit, _reason -> :ok
        end
      end

      cleanup(handle)
    end

    defp command(handle, operation, arguments, timeout) do
      args =
        Map.merge(arguments, %{
          owner: handle.owner,
          generation: handle.generation,
          control_token: handle.control_token
        })

      Snakepit.GRPCWorker.execute(handle.worker, operation, args, timeout,
        affinity: :strict_fail_fast,
        idempotent: false
      )
    end

    defp register_bridge(session_id, bridge, generation, opts) do
      timeout = Keyword.get(opts, :callback_timeout, 2_000)

      handler = fn params ->
        case params do
          %{
            "generation" => ^generation,
            "execution_id" => id,
            "operation" => operation,
            "arguments" => arguments
          } ->
            Bridge.call(
              bridge,
              generation,
              id,
              bridge_operation(operation, arguments),
              timeout + 1_000
            )

          _ ->
            %{"ok" => false, "error" => "stale_generation"}
        end
      end

      ToolRegistry.register_elixir_tool(session_id, "omj_eval", handler, %{
        exposed_to_python: true
      })
    end

    defp bridge_operation("tool", [name, parameters]), do: {:tool, name, parameters}
    defp bridge_operation("display", [value]), do: {:display, value}

    defp bridge_operation("artifact", [name, media_type, data]),
      do: {:artifact, name, media_type, data}

    defp bridge_operation("artifact_bytes", [name, media_type, data]) when is_binary(data) do
      case Base.decode64(data) do
        {:ok, bytes} -> {:artifact, name, media_type, bytes}
        :error -> :invalid
      end
    end

    defp bridge_operation("output", ["stdout", text, clipped?]),
      do: {:output, :stdout, text, clipped?}

    defp bridge_operation("output", ["stderr", text, clipped?]),
      do: {:output, :stderr, text, clipped?}

    defp bridge_operation(_operation, _arguments), do: :invalid

    defp same_worker(%{worker: worker, worker_id: id}) when is_pid(worker) do
      case WorkerRegistry.get_worker_pid(id) do
        {:ok, ^worker} -> if Process.alive?(worker), do: :ok, else: {:error, :python_worker_lost}
        _ -> {:error, :python_worker_replaced}
      end
    end

    defp same_worker(_handle), do: {:error, :python_worker_lost}

    defp same_identity(handle, %{"generation" => generation, "worker_token" => token}) do
      if handle.generation == generation and handle.token == token,
        do: :ok,
        else: {:error, :python_generation_changed}
    end

    defp same_identity(_handle, _result), do: {:error, :python_identity_missing}

    defp status("ok"), do: {:ok, :ok}
    defp status("error"), do: {:ok, :error}
    defp status(_status), do: {:error, :invalid_python_status}

    defp isolation(opts) do
      case {Keyword.get(opts, :isolation), Keyword.get(opts, :launcher)} do
        {:trusted, _launcher} ->
          :ok

        {:os, executable} when is_binary(executable) ->
          configured = Snakepit.Adapters.GRPCPython.executable_path() |> to_string()

          if Path.type(executable) == :absolute and File.regular?(executable) and
               configured == executable, do: :ok, else: {:error, {:isolation_required, :python}}

        _ ->
          {:error, {:isolation_required, :python}}
      end
    end

    defp private_diagnostics do
      if Code.ensure_loaded?(Snakepit.GRPCWorker) and
           function_exported?(Snakepit.GRPCWorker, :private_diagnostics_version, 0) and
           Function.capture(Snakepit.GRPCWorker, :private_diagnostics_version, 0).() == 1,
         do: :ok,
         else:
           {:error, {:backend_unavailable, :python, :snakepit_private_diagnostics_unavailable}}
    end

    defp prerequisites do
      required = [
        SessionStore,
        ToolRegistry,
        WorkerSupervisor,
        Snakepit.GRPC.Listener,
        Snakepit.Pool.Worker.StarterRegistry,
        GRPC.Client.Supervisor,
        GRPC.Client.Registry,
        Snakepit.Pool.Registry,
        Snakepit.Pool.ProcessRegistry,
        Snakepit.ETSOwner,
        Snakepit.TaskSupervisor,
        Snakepit.Worker.LifecycleManager,
        :ranch_sup
      ]

      if Enum.all?(required, &is_pid(Process.whereis(&1))),
        do: :ok,
        else: {:error, {:backend_unavailable, :python, :snakepit_runtime_not_started}}
    end

    defp worker_config(opts, owner, control_token) do
      root = Application.app_dir(:oh_my_jido, "priv/oh_my_jido/eval/python")
      snakepit = Application.app_dir(:snakepit, "priv/python")

      env =
        opts
        |> Keyword.get(:adapter_env, [])
        |> Map.new()
        |> Map.put(
          "PYTHONPATH",
          Enum.join([root, snakepit], if(match?({:win32, _}, :os.type()), do: ";", else: ":"))
        )
        |> Map.put("OH_MY_JIDO_EVAL_OWNER", owner)
        |> Map.put("OH_MY_JIDO_EVAL_CONTROL_TOKEN", control_token)

      %{
        adapter_args: ["--adapter", "oh_my_jido_eval.adapter.EvalAdapter"],
        adapter_env: env,
        private_diagnostics: true,
        worker_ttl: :infinity,
        worker_max_requests: :infinity
      }
    end

    defp cleanup(handle) do
      bridge = Keyword.fetch!(handle.opts, :bridge)

      sessions =
        try do
          Bridge.python_sessions(bridge, handle.worker_id)
        catch
          :exit, _reason -> []
        end

      result = release_worker(handle.worker_id, [handle.session_id | sessions])

      if is_pid(bridge) and Process.alive?(bridge),
        do: Bridge.forget_python(bridge, handle.worker_id)

      result
    end

    @doc false
    def release_worker(id, known_sessions) do
      # Synchronize with any in-flight managed start before looking up its lease.
      # This also covers a controller killed while start_worker/5 was blocked.
      _workers = WorkerSupervisor.list_workers()
      session_id = worker_session(id)

      case WorkerRegistry.get_worker_pid(id) do
        {:ok, worker} ->
          try do
            GenServer.stop(worker, {:shutdown, :omj_eval_interrupt}, 5_000)
          catch
            :exit, _reason -> :ok
          end

        _ ->
          :ok
      end

      result = WorkerSupervisor.stop_worker(id)

      for session <- Enum.uniq([session_id | known_sessions]), is_binary(session) do
        ToolRegistry.cleanup_session(session)
        SessionStore.delete_session(session)
      end

      case result do
        :ok -> :ok
        {:error, :worker_not_found} -> :ok
        {:error, reason} -> {:error, {:python_cleanup_failed, reason}}
      end
    catch
      :exit, reason -> {:error, {:python_cleanup_failed, reason}}
    end

    defp worker_session(id) do
      with {:ok, worker} <- WorkerRegistry.get_worker_pid(id),
           {:ok, session_id} <- Snakepit.GRPCWorker.get_session_id(worker),
           do: session_id
    catch
      :exit, _reason -> nil
    end
  else
    @impl true
    def open(_context, _opts),
      do: {:error, {:backend_unavailable, :python, :dependency_not_available}}

    @impl true
    def execute(_handle, _request),
      do: {:error, {:backend_unavailable, :python, :dependency_not_available}}

    @impl true
    def interrupt(_handle, _execution_id),
      do: {:error, {:backend_unavailable, :python, :dependency_not_available}}

    @impl true
    def reset(_handle), do: {:error, {:backend_unavailable, :python, :dependency_not_available}}

    @impl true
    def close(_handle), do: {:error, {:backend_unavailable, :python, :dependency_not_available}}

    @doc false
    def release_worker(_id, _known_sessions),
      do: {:error, {:backend_unavailable, :python, :dependency_not_available}}
  end
end
