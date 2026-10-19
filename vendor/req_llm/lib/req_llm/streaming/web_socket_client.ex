# Modified by Oh-My-Jido contributors, 2026-10-13: model-bound normalization
# before WebSocket attach/task diagnostics and native failure propagation.
# Original ReqLLM 1.28.0: Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule ReqLLM.Streaming.WebSocketClient do
  @moduledoc false

  alias ReqLLM.Streaming.Failure
  alias ReqLLM.Streaming.Fixtures.HTTPContext
  alias ReqLLM.Streaming.WebSocketProtocol
  alias ReqLLM.Streaming.WebSocketSession
  alias ReqLLM.StreamServer

  require ReqLLM.Debug, as: Debug

  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid(), atom()) ::
          {:ok, pid(), HTTPContext.t(), map()} | {:error, term()}
  def start_stream(
        provider_mod,
        model,
        context,
        opts,
        stream_server_pid,
        _finch_name \\ ReqLLM.Finch
      ) do
    case maybe_replay_fixture(model, opts) do
      {:fixture, fixture_path} ->
        Debug.dbug(
          fn ->
            test_name = Keyword.get(opts, :fixture, Path.basename(fixture_path, ".json"))
            "step: model=#{LLMDB.Model.spec(model)}, name=#{test_name}"
          end,
          component: :streaming
        )

        start_fixture_replay(fixture_path, stream_server_pid, model)

      :no_fixture ->
        with {:ok, config} <- build_stream_request(provider_mod, model, context, opts),
             {:ok, task_pid} <-
               start_streaming_task(config, stream_server_pid, provider_mod, model, context, opts) do
          {:ok, task_pid, config.http_context, config.canonical_json}
        end
    end
  rescue
    error ->
      error_context = Failure.error_context(provider_mod, model, opts)

      if Failure.normalizer?(error_context),
        do: Failure.build_failure(error, :build_request_failed, error_context),
        else: reraise(error, __STACKTRACE__)
  catch
    kind, reason ->
      error_context = Failure.error_context(provider_mod, model, opts)

      if Failure.normalizer?(error_context),
        do: Failure.build_failure({kind, reason}, :build_request_failed, error_context),
        else: :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp build_stream_request(provider_mod, model, context, opts) do
    with true <- function_exported?(provider_mod, :attach_websocket_stream, 3),
         {:ok, config} <- provider_mod.attach_websocket_stream(model, context, opts) do
      http_context =
        Map.get_lazy(config, :http_context, fn ->
          HTTPContext.new(config.url, :get, Map.new(config.headers || []))
        end)

      {:ok,
       %{
         url: config.url,
         headers: config.headers || [],
         initial_messages: config.initial_messages || [],
         http_context: http_context,
         canonical_json: config.canonical_json || %{},
         fallback_transport: Map.get(config, :fallback_transport)
       }}
    else
      false ->
        {:error,
         Failure.normalize(
           ReqLLM.Error.API.Request.exception(
             reason:
               "#{inspect(provider_mod)} does not implement WebSocket streaming for #{LLMDB.Model.spec(model)}"
           ),
           Failure.error_context(provider_mod, model, opts)
         )}

      {:error, reason} ->
        Failure.build_failure(reason, :provider_build_failed, Failure.error_context(provider_mod, model, opts))
    end
  rescue
    error ->
      Failure.build_failure(error, :build_request_failed, Failure.error_context(provider_mod, model, opts))
  catch
    kind, reason ->
      error_context = Failure.error_context(provider_mod, model, opts)

      if Failure.normalizer?(error_context),
        do: Failure.build_failure({kind, reason}, :build_request_failed, error_context),
        else: :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp start_fixture_replay(fixture_path, stream_server_pid, _model) do
    case Code.ensure_loaded(ReqLLM.Test.VCR) do
      {:module, module} ->
        {:ok, task_pid} =
          Function.capture(module, :replay_into_stream_server, 2).(
            fixture_path,
            stream_server_pid
          )

        Process.link(task_pid)

        transcript = Function.capture(module, :load!, 1).(fixture_path)
        canonical_json = Map.get(transcript.request, :canonical_json, %{})
        request_headers = Map.get(transcript.request, :headers, %{})
        response_headers = Function.capture(module, :headers, 1).(transcript)
        status = Function.capture(module, :status, 1).(transcript)

        http_context =
          transcript.request.url
          |> HTTPContext.new(:get, request_headers)
          |> HTTPContext.update_response(status, Map.new(response_headers))

        {:ok, task_pid, http_context, canonical_json}

      {:error, _} ->
        {:error, :vcr_not_available}
    end
  end

  defp start_streaming_task(config, stream_server_pid, provider_mod, model, context, opts) do
    error_context = Failure.error_context(provider_mod, model, opts)
    stream_opts = Keyword.put(opts, :provider_error_context, error_context)

    task_pid =
      Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
        try do
          session = reusable_session(stream_opts)

          result =
            case session do
              nil ->
                start_owned_session(config, stream_server_pid, stream_opts)

              session_pid when is_pid(session_pid) ->
                await_connect_and_stream(session_pid, stream_server_pid, stream_opts,
                  initial_messages: config.initial_messages,
                  close_on_terminal?: false
                )
            end

          maybe_fallback_to_http(
            result,
            config,
            stream_server_pid,
            provider_mod,
            model,
            context,
            stream_opts,
            session
          )
        catch
          kind, reason ->
            if Failure.normalizer?(error_context) do
              {:error, error} =
                forward_stream_failure(stream_server_pid, {kind, reason}, stream_opts)
              Failure.log(error)
              {:error, error}
            else
              :erlang.raise(kind, reason, __STACKTRACE__)
            end
        end
      end)

    {:ok, task_pid.pid}
  rescue
    error ->
      Failure.build_failure(error, :task_start_failed, Failure.error_context(provider_mod, model, opts))
  catch
    kind, reason ->
      error_context = Failure.error_context(provider_mod, model, opts)

      if Failure.normalizer?(error_context),
        do: Failure.build_failure({kind, reason}, :task_start_failed, error_context),
        else: :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp start_owned_session(config, stream_server_pid, opts) do
    connect_timeout = connect_timeout(opts)

    case WebSocketSession.start_link(
           config.url,
           headers: config.headers,
           initial_messages: config.initial_messages,
           connect_timeout: connect_timeout
         ) do
      {:ok, session_pid} ->
        result =
          await_connect_and_stream(session_pid, stream_server_pid, opts, close_on_terminal?: true)

        close_owned_session(session_pid)
        result

      {:error, reason} ->
        forward_stream_failure(stream_server_pid, reason, opts)
    end
  end

  defp await_connect_and_stream(session_pid, stream_server_pid, opts, session_opts) do
    case WebSocketSession.await_connected(session_pid, connect_timeout(opts)) do
      :ok ->
        safe_http_event(stream_server_pid, {:status, 101})
        safe_http_event(stream_server_pid, {:headers, [{"upgrade", "websocket"}]})

        case send_initial_messages(session_pid, Keyword.get(session_opts, :initial_messages, [])) do
          :ok ->
            relay_messages(
              session_pid,
              stream_server_pid,
              opts,
              [close_on_terminal?: Keyword.get(session_opts, :close_on_terminal?, true)],
              false
            )

          {:error, reason} ->
            forward_stream_failure(stream_server_pid, reason, opts)
        end

      {:error, reason} ->
        forward_stream_failure(stream_server_pid, reason, opts)
    end
  end

  defp relay_messages(session_pid, stream_server_pid, opts, relay_opts, output_observed?) do
    case WebSocketSession.next_message(session_pid, receive_timeout(opts)) do
      {:ok, message} ->
        case WebSocketProtocol.decode_message(message) do
          {:ok, decoded} ->
            if WebSocketProtocol.error_event?(%{data: decoded}) do
              forward_stream_failure(
                stream_server_pid,
                decoded,
                {:websocket_error_event, decoded},
                opts
              )
            else
              safe_http_event(stream_server_pid, {:data, message})

              if WebSocketProtocol.terminal_event?(%{data: decoded}) do
                maybe_close_session(
                  session_pid,
                  Keyword.get(relay_opts, :close_on_terminal?, true)
                )
              else
                relay_messages(session_pid, stream_server_pid, opts, relay_opts, true)
              end
            end

          {:error, reason} ->
            forward_stream_failure(
              stream_server_pid,
              reason,
              {:invalid_websocket_message, reason},
              opts
            )
        end

      :halt ->
        :ok

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        if message_too_big?(reason) do
          {:websocket_error, reason, output_observed?}
        else
          forward_stream_failure(stream_server_pid, reason, opts)
        end
    end
  end

  defp maybe_fallback_to_http(
         {:websocket_error, reason, false},
         %{fallback_transport: :http},
         stream_server_pid,
         provider_mod,
         model,
         context,
         opts,
         session
       ) do
    mark_session_http_fallback(session)

    http_opts =
      opts
      |> Keyword.delete(:stream_transport)
      |> Keyword.update(:provider_options, [], fn provider_opts ->
        provider_opts
        |> Keyword.put(:openai_stream_transport, :sse)
        |> Keyword.delete(:openai_websocket_session)
      end)

    finch_name = Keyword.get(opts, :finch_name, ReqLLM.Finch)

    case ReqLLM.Streaming.FinchClient.build_stream_request(
           provider_mod,
           model,
           context,
           http_opts,
           finch_name
         ) do
      {:ok, finch_request, http_context, canonical_json} ->
        safe_http_event(
          stream_server_pid,
          {:transport_fallback, :http,
           Failure.normalize(reason, Keyword.get(opts, :provider_error_context)),
           http_context, canonical_json}
        )
        ReqLLM.Streaming.FinchClient.run_stream(
          finch_request,
          stream_server_pid,
          finch_name,
          http_opts
        )

      {:error, fallback_reason} ->
        forward_stream_failure(stream_server_pid, fallback_reason, opts)
    end
  end

  defp maybe_fallback_to_http(
         {:websocket_error, reason, _output_observed?},
         _config,
         stream_server_pid,
         _provider_mod,
         _model,
         _context,
         opts,
         _session
       ) do
    forward_stream_failure(stream_server_pid, reason, opts)
  end

  defp maybe_fallback_to_http(
         result,
         _config,
         _stream_server_pid,
         _provider_mod,
         _model,
         _context,
         _opts,
         _session
       ),
       do: result

  defp message_too_big?({side, 1009, _detail}) when side in [:local, :remote], do: true
  defp message_too_big?(_reason), do: false

  defp mark_session_http_fallback(session) when is_pid(session) do
    WebSocketSession.mark_http_fallback(session)
  catch
    :exit, _reason -> :ok
  end

  defp mark_session_http_fallback(_session), do: :ok

  defp close_owned_session(session) do
    WebSocketSession.close(session)
  catch
    :exit, _reason -> :ok
  end

  defp reusable_session(opts) do
    opts
    |> Keyword.get(:provider_options, [])
    |> Keyword.get(:openai_websocket_session)
  end

  defp send_initial_messages(session_pid, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case WebSocketSession.send_text(session_pid, message) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_close_session(session_pid, true), do: WebSocketSession.close(session_pid)
  defp maybe_close_session(_session_pid, false), do: :ok

  defp connect_timeout(opts) do
    Keyword.get(opts, :connect_timeout, Application.get_env(:req_llm, :connect_timeout, 10_000))
  end

  defp receive_timeout(opts) do
    Keyword.get_lazy(opts, :receive_timeout, fn ->
      Application.get_env(
        :req_llm,
        :stream_receive_timeout,
        Application.get_env(:req_llm, :receive_timeout, 30_000)
      )
    end)
  end

  defp maybe_replay_fixture(model, opts) do
    case Code.ensure_loaded(ReqLLM.Test.Fixtures) do
      {:module, mod} -> mod.replay_path(model, opts)
      {:error, _} -> :no_fixture
    end
  end

  defp forward_stream_failure(server, reason, opts),
    do: forward_stream_failure(server, reason, reason, opts)

  defp forward_stream_failure(server, reason, event_reason, opts) do
    error_context = Keyword.get(opts, :provider_error_context)
    event_reason = Failure.normalize(event_reason, error_context)
    safe_http_event(server, {:error, event_reason})

    if Failure.normalizer?(error_context),
      do: {:error, event_reason},
      else: {:error, reason}
  end

  defp safe_http_event(server, event) do
    StreamServer.http_event(server, event)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
    :exit, {{:shutdown, _}, _} -> :ok
  end
end
