defmodule OhMyJido.Eval.Peer do
  @moduledoc false
  @behaviour OhMyJido.Eval.Backend

  alias OhMyJido.Eval.PortOwner

  # "Peer" denotes the separate ERTS, not OTP :peer. Stock :peer's alternative
  # channel forwards arbitrary worker-controlled BEAM messages into its origin;
  # this backend deliberately uses a data-only, bounded JSON Port instead.
  @impl true
  def open(context, opts) do
    language = Keyword.fetch!(opts, :language)

    with :ok <- isolation(opts, language),
         {:ok, executable} <- executable(opts),
         {:ok, opts} <- bootstrap(opts, language),
         {:ok, worker} <- PortOwner.start_link(executable, args(opts), context.workspace, opts) do
      try do
        case PortOwner.open(
               worker,
               language,
               context.workspace,
               opts,
               Keyword.get(opts, :boot_timeout, 15_000)
             ) do
          {:ok, lease} ->
            {:ok, Map.merge(lease, %{worker: worker, context: context, opts: opts})}

          {:error, reason} ->
            stop(worker)
            {:error, {:backend_unavailable, language, reason}}
        end
      catch
        kind, reason ->
          stop(worker)
          {:error, {:backend_unavailable, language, {kind, reason}}}
      end
    end
  rescue
    exception ->
      {:error,
       {:backend_unavailable, Keyword.fetch!(opts, :language), Exception.message(exception)}}
  end

  @impl true
  def execute(handle, request) do
    PortOwner.execute(handle.worker, request)
  catch
    kind, reason -> {:error, {:peer_lost, {kind, reason}}}
  end

  @impl true
  def interrupt(handle, _execution_id) do
    result = OhMyJido.Process.terminate_group(handle.os_pid, handle.os_identity)
    Process.exit(handle.worker, :kill)
    result
  end

  @impl true
  def reset(handle) do
    with :ok <- close(handle) do
      open(handle.context, Keyword.update!(handle.opts, :generation, &(&1 + 1)))
    end
  end

  @impl true
  def close(handle), do: interrupt(handle, nil)

  def isolation(opts, language) do
    case {Keyword.get(opts, :isolation), Keyword.get(opts, :launcher)} do
      {:trusted, _launcher} ->
        :ok

      {:os, {executable, prefix}} when is_binary(executable) and is_list(prefix) ->
        if Path.type(executable) == :absolute and File.regular?(executable) and
             Enum.all?(prefix, &is_binary/1),
           do: :ok,
           else: {:error, {:isolation_required, language}}

      _ ->
        {:error, {:isolation_required, language}}
    end
  end

  defp bootstrap(opts, :elixir), do: {:ok, opts}

  defp bootstrap(opts, :javascript) do
    path = Application.app_dir(:oh_my_jido, "priv/oh_my_jido/eval/javascript.js")

    case File.read(path) do
      {:ok, source} -> {:ok, Keyword.put(opts, :bootstrap, source)}
      {:error, reason} -> {:error, {:backend_unavailable, :javascript, reason}}
    end
  end

  defp executable(opts) do
    case {System.find_executable("setsid"), :os.find_executable(~c"erl")} do
      {nil, _erl} ->
        {:error,
         {:backend_unavailable, Keyword.fetch!(opts, :language), :process_supervision_unavailable}}

      {_setsid, false} ->
        {:error, {:backend_unavailable, Keyword.fetch!(opts, :language), :erts_not_found}}

      {setsid, erl} ->
        {executable, prefix} =
          case Keyword.get(opts, :launcher) do
            nil ->
              {erl, []}

            {launcher, prefix} ->
              {String.to_charlist(launcher), Enum.map(prefix, &String.to_charlist/1) ++ [erl]}
          end

        {:ok, {String.to_charlist(setsid), [~c"--wait", ~c"--", executable] ++ prefix}}
    end
  end

  defp args(opts) do
    schedulers = Keyword.get(opts, :schedulers, 2)

    [
      ~c"+S",
      String.to_charlist(Integer.to_string(schedulers)),
      ~c"+A",
      ~c"1",
      ~c"-noshell",
      ~c"-noinput",
      ~c"-user",
      ~c"Elixir.OhMyJido.Eval.PortKernel",
      ~c"-pa"
    ] ++ :code.get_path()
  end

  defp stop(worker) do
    if Process.alive?(worker), do: GenServer.stop(worker, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
