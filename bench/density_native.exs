defmodule OhMyJido.Bench.Density.Native do
  @moduledoc false

  import Jido.AI.Test

  @input "density input\n"
  @model "anthropic:claude-sonnet-4-6"

  def model, do: @model
  def tools, do: [OhMyJido.Tools.Read, OhMyJido.Tools.Write, OhMyJido.Tools.Shell]
  def finch, do: __MODULE__.Gateway

  def gateway_child_spec do
    Supervisor.child_spec(
      {Finch, name: finch(), pools: %{default: [protocols: [:http1], size: 1, count: 1]}},
      id: finch()
    )
  end

  def input, do: @input
  def content(token), do: "density output #{token}\n"

  def task(token),
    do: "Read the input, create the output and process it for density job #{token}."

  def final_answer(token), do: "Density job #{token} finished."

  def metadata(token, observer, config) do
    process_ms = Enum.at(config.process_ms, rem(:erlang.phash2(token), length(config.process_ms)))

    %{
      density_benchmark: %{
        token: token,
        observer: observer,
        model_ms: config.model_ms,
        tool_ms: config.tool_ms,
        process_ms: process_ms,
        shell: System.find_executable("sh")
      }
    }
  end

  def prepare_workspace(root) do
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "input.txt"), @input, [:exclusive])
  end

  def script(token, metadata, tool_timeout_ms) do
    settings = metadata.density_benchmark

    script =
      expect_react do
        user(task(token))
        call("read", %{path: "input.txt"}, id: "#{token}-read")

        call("write", %{path: "output.txt", content: content(token), snapshot: "missing"},
          id: "#{token}-write"
        )

        call(
          "shell",
          %{
            executable: settings.shell,
            args: shell_args(settings.process_ms),
            cwd: "nested",
            env: %{"OMJ_DENSITY_CHILD" => token},
            timeout_ms: tool_timeout_ms,
            max_output_bytes: 1_024
          },
          id: "#{token}-shell"
        )

        answer(final_answer(token))
      end

    {task(token), react_opts(script)}
  end

  def warmup_script do
    script =
      expect_react do
        user("Initialize the density benchmark's native scripted model gateway.")
        answer(final_answer("gateway-warmup"))
      end

    {script.user, react_opts(script)}
  end

  def shell_args(delay_ms) do
    seconds = :erlang.float_to_binary(delay_ms / 1_000, decimals: 3)

    [
      "-c",
      """
      test "$(cat ../output.txt)" = "density output $OMJ_DENSITY_CHILD" || exit 41
      sleep #{seconds} || exit 42
      printf '%s\\n' "$OMJ_DENSITY_CHILD" > ../child-env.txt || exit 43
      pwd > ../child-cwd.txt || exit 44
      printf 'processed:%s\\n' "$OMJ_DENSITY_CHILD" > ../receipt.txt || exit 45
      printf 'density stdout:%s\\n' "$OMJ_DENSITY_CHILD"
      printf 'density stderr\\n' >&2
      """
    ]
  end

  def settings(context) do
    case context.metadata do
      %{density_benchmark: %{token: token, observer: observer} = settings}
      when is_binary(token) and is_pid(observer) ->
        {:ok, settings}

      _other ->
        {:error, :missing_density_fixture}
    end
  end

  def delay(milliseconds) when is_integer(milliseconds) and milliseconds in 0..2_000 do
    started = System.monotonic_time(:microsecond)
    Process.sleep(milliseconds)
    {:ok, (System.monotonic_time(:microsecond) - started) / 1_000}
  end

  def delay(_milliseconds), do: {:error, :invalid_density_delay}
end

defmodule OhMyJido.Bench.Density.Native.Transformer do
  @moduledoc false
  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  alias OhMyJido.Bench.Density.Native

  @impl true
  def transform_request(request, state, config, runtime_context) do
    with {:ok, overrides} <-
           OhMyJido.Models.Transformer.transform_request(request, state, config, runtime_context),
         {:ok, context} <- OhMyJido.Context.fetch(runtime_context),
         {:ok, settings} <- Native.settings(context),
         true <- Keyword.has_key?(overrides.llm_opts, :jido_ai_react_script),
         requested <-
           Enum.at(settings.model_ms, rem(state.iteration - 1, length(settings.model_ms))),
         {:ok, elapsed} <- Native.delay(requested) do
      send(
        settings.observer,
        {:density_delay, settings.token, :model, state.iteration, requested, elapsed}
      )

      http_options =
        overrides.llm_opts
        |> Keyword.get(:req_http_options, [])
        |> Keyword.put(:finch, name: Native.finch())

      {:ok,
       %{overrides | llm_opts: Keyword.put(overrides.llm_opts, :req_http_options, http_options)}}
    else
      false -> {:error, :density_requires_an_explicit_native_script}
      {:error, _reason} = error -> error
    end
  end
end

defmodule OhMyJido.Bench.Density.Native.Host do
  @moduledoc false
  @behaviour OhMyJido.Host

  alias OhMyJido.Bench.Density.Native

  @impl true
  def authorize(context, capability, effect, _opts) do
    with {:ok, settings} <- Native.settings(context),
         true <- allowed?(context, settings, capability, effect),
         requested <- Map.fetch!(settings.tool_ms, capability),
         {:ok, elapsed} <- Native.delay(requested) do
      send(
        settings.observer,
        {:density_delay, settings.token, :tool_authorization, capability, requested, elapsed}
      )

      :ok
    else
      false -> {:error, :density_effect_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def credentials(context, _account, _opts) do
    notify(context, :credential_callback_requested)
    {:error, :density_has_no_credentials}
  end

  @impl true
  def invoke(context, _capability, _request, _opts) do
    notify(context, :unexpected_host_invocation)
    {:error, :density_capability_unavailable}
  end

  @impl true
  def question(context, _question, _opts) do
    notify(context, :unexpected_host_question)
    {:error, :density_has_no_approval_provider}
  end

  defp allowed?(_context, _settings, :read, %{operation: :read, path: "input.txt"}), do: true
  defp allowed?(_context, _settings, :edit, %{operation: :write, path: "output.txt"}), do: true

  defp allowed?(context, settings, :exec, effect) do
    effect[:executable] == settings.shell and
      effect[:args] == Native.shell_args(settings.process_ms) and
      effect[:cwd] == Path.join(context.workspace, "nested") and
      effect[:env] == %{"OMJ_DENSITY_CHILD" => settings.token}
  end

  defp allowed?(_context, _settings, _capability, _effect), do: false

  defp notify(context, kind) do
    case Native.settings(context) do
      {:ok, settings} -> send(settings.observer, {:density_host_error, settings.token, kind})
      {:error, _reason} -> :ok
    end
  end
end
