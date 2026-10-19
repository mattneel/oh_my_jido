defmodule OhMyJido.Extensions.Artifact do
  @moduledoc """
  Approved host interpretation of a regular file inside the session workspace.

  Bind `invoke/3` under `context.adapters.artifact`. Only `:inspect` and
  `:read_text` are admitted. The authorized request contains a confined absolute
  path, relative display path, kind, stat size and input/output caps. It cannot
  select a host method, executable, URL or RPC operation. Content and interpreter
  descriptions are untrusted. Returned extra metadata is deliberately omitted.

  Callbacks must recheck confinement at their actual file-open boundary, enforce
  input/output limits, and close readers/decoder resources before returning. A
  decoder needing network or other effects must obtain additional host approval;
  the artifact grant covers local reading, not remote upload or code execution.
  Persistent host decoder resources may implement `close_session/2`.

  `OhMyJido.Extensions.Artifact.Local` is an execution-free reference adapter for
  UTF-8 text, PNG/GIF header dimensions and binary identity. Other image formats
  require an explicitly supplied host decoder, not a pretend successful decode.
  """

  alias OhMyJido.{Context, Host, Tool, Workspace}
  import OhMyJido.Extensions.Text, only: [text: 2]

  @type request :: %{
          operation: :inspect | :read_text,
          path: String.t(),
          relative_path: String.t(),
          kind: :auto | :image | :text | :binary,
          bytes: non_neg_integer(),
          max_input_bytes: pos_integer(),
          max_output_bytes: pos_integer()
        }
  @callback invoke(Context.t(), request(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback close_session(Context.t(), keyword()) :: :ok | {:error, term()}
  @optional_callbacks close_session: 2

  @doc false
  def perform(context, params) do
    with {:ok, request} <- request(context, params),
         :ok <-
           Tool.authorize(context, :artifact, %{
             operation: request.operation,
             path: params.path,
             kind: request.kind,
             sensitive: false,
             external: false,
             mutates: false
           }),
         {:ok, request} <- confine(context, request),
         {:ok, result} <- invoke(context, request) do
      response(request, result)
    end
  end

  defp invoke(context, request) do
    context
    |> Host.call(:invoke, [:artifact, request])
    |> host_response()
  end

  defp host_response({:ok, result} = response) when is_map(result), do: response
  defp host_response({:error, reason} = response) when is_atom(reason), do: response

  defp host_response({:error, {:capability_unavailable, :artifact}} = response), do: response

  defp host_response({:error, {:unsupported_artifact_format, :image}} = response), do: response

  defp host_response({:error, {:artifact_too_large, size, cap}} = response)
       when is_integer(size) and is_integer(cap),
       do: response

  defp host_response({:error, %{effect: :uncertain}}),
    do: {:error, %{reason: :host_callback_failed, capability: :artifact, effect: :uncertain}}

  defp host_response({:error, _reason}),
    do: {:error, %{reason: :host_callback_failed, capability: :artifact, effect: :unknown}}

  defp host_response(_invalid), do: {:error, {:invalid_host_response, :artifact}}

  @doc "Human-initiated artifact smoke; opens an actual confined input through the configured adapter."
  def smoke(execution_context, path, opts \\ []) do
    if Keyword.get(opts, :human_initiated, false) do
      with {:ok, result} <-
             OhMyJido.Tools.Artifact.run(%{operation: "inspect", path: path}, execution_context) do
        {:ok, %{observed: true, artifact: result}}
      end
    else
      {:error, :human_initiated_required}
    end
  end

  defp request(context, params) do
    input_cap = Map.get(context.limits, :artifact_input_bytes, 33_554_432)
    output_cap = Map.get(context.limits, :artifact_output_bytes, 131_072)

    if positive_cap?(input_cap) and positive_cap?(output_cap) and valid_path?(params.path) and
         text_operation?(params.operation, params.kind) do
      {:ok,
       %{
         operation: operation(params.operation),
         path: params.path,
         kind: kind(params.kind),
         max_input_bytes: min(params.max_input_bytes, input_cap),
         max_output_bytes: min(params.max_output_bytes, output_cap)
       }}
    else
      {:error, :invalid_artifact_request}
    end
  end

  defp positive_cap?(cap), do: is_integer(cap) and cap > 0

  defp valid_path?(path),
    do: byte_size(path) <= 4096 and String.valid?(path) and not String.contains?(path, <<0>>)

  defp text_operation?(operation, kind),
    do: not (operation == "read_text" and kind in ["image", "binary"])

  defp operation("inspect"), do: :inspect
  defp operation("read_text"), do: :read_text
  defp kind("auto"), do: :auto
  defp kind("image"), do: :image
  defp kind("text"), do: :text
  defp kind("binary"), do: :binary

  defp confine(context, request) do
    with {:ok, path} <- Workspace.resolve(context, request.path),
         {:ok, stat} <- File.stat(path),
         :ok <- regular_input(stat, request.max_input_bytes),
         relative_path when is_binary(relative_path) <- Workspace.relative(context, path) do
      {:ok, Map.merge(request, %{path: path, relative_path: relative_path, bytes: stat.size})}
    end
  end

  defp regular_input(%File.Stat{type: :regular, size: size}, cap) when size <= cap, do: :ok

  defp regular_input(%File.Stat{type: :regular, size: size}, cap),
    do: {:error, {:artifact_too_large, size, cap}}

  defp regular_input(_stat, _cap), do: {:error, :artifact_not_regular}

  defp response(request, %{summary: summary, media_type: media_type} = result) do
    content = Map.get(result, :content, "")

    with true <- text?(summary) and text?(content),
         true <- text?(media_type) and byte_size(media_type) <= 128 and media_type != "",
         true <- valid_metadata?(result),
         {:ok, parts} <- model_inputs(request, result) do
      {summary, summary_clipped} = text(summary, request.max_output_bytes)
      {content, content_clipped} = text(content, request.max_output_bytes - byte_size(summary))
      limits = limitations(Map.get(result, :limitations, []))
      metadata = Map.take(result, [:width, :height, :sha256, :bytes])

      {:ok,
       Map.merge(metadata, %{
         operation: request.operation,
         path: request.relative_path,
         media_type: media_type,
         summary: summary,
         content: content,
         trust: :untrusted,
         truncated:
           summary_clipped or content_clipped or Map.get(result, :truncated, false) == true,
         limitations: limits,
         limits: %{text_bytes: request.max_output_bytes, input_bytes: request.max_input_bytes},
         __content_parts__: parts
       })}
    else
      _invalid -> {:error, {:invalid_host_response, :artifact}}
    end
  end

  defp response(_request, _result), do: {:error, {:invalid_host_response, :artifact}}

  defp model_inputs(request, result) do
    model_parts(request, Map.get(result, :__content_parts__, []))
  end

  defp model_parts(_request, []), do: {:ok, []}

  defp model_parts(
         request,
         [%ReqLLM.Message.ContentPart{type: :image, data: bytes, media_type: media_type}] = parts
       )
       when is_binary(bytes) and is_binary(media_type) do
    if String.starts_with?(media_type, "image/") and byte_size(bytes) <= request.max_input_bytes,
      do: {:ok, parts},
      else: {:error, {:invalid_host_response, :artifact}}
  end

  defp model_parts(_request, _parts), do: {:error, {:invalid_host_response, :artifact}}

  defp valid_metadata?(result) do
    Enum.all?([:width, :height, :bytes], &integer_metadata?(result, &1)) and
      sha256_metadata?(result)
  end

  defp integer_metadata?(result, key) do
    case Map.fetch(result, key) do
      :error -> true
      {:ok, value} -> is_integer(value) and value >= 0 and value <= 4_294_967_295
    end
  end

  defp sha256_metadata?(result) do
    case Map.fetch(result, :sha256) do
      :error ->
        true

      {:ok, hash} ->
        is_binary(hash) and byte_size(hash) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
    end
  end

  defp limitations(values) when is_list(values) do
    values
    |> Enum.take(5)
    |> Enum.filter(&text?/1)
    |> Enum.map(fn value -> elem(text(value, 256), 0) end)
  end

  defp limitations(_values), do: ["Host limitations were not supplied as a bounded text list"]

  defp text?(value), do: is_binary(value) and String.valid?(value)
end
