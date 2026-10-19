defmodule OhMyJido.Models.Subscription do
  @moduledoc """
  SIWC preview policy over ReqLLM's public OpenAI Responses encoder and transport.

  `options/1` supplies explicit OAuth credentials and ReqLLM's existing
  `on_finch_request` seam. `configure/3` validates caller choices, selects the
  Responses wire metadata, and removes the model's automatic output limit.
  The hook shapes the already-encoded body; it does not send HTTP, parse SSE,
  refresh credentials, or switch billing modes.

  Jido-generated max-token and sampling defaults must be identified explicitly
  through `:generated_options`. User-supplied unsupported options are errors,
  not silently discarded preferences. Function schemas and call/result history
  remain encoded by ReqLLM, with functions offered as developer additional tools.

  A narrow registered provider delegates the installed public OpenAI transport
  and Responses decoder, replacing only terminal diagnostic metadata with typed
  safe errors before ReqLLM materialization and Jido's native failure boundary.
  """

  alias OhMyJido.Auth.Error
  alias OhMyJido.Models.Subscription.Provider

  @base_url "https://api.openai.com/v1"
  @bearer_pattern ~r/\A[A-Za-z0-9._~+\/-]+=*\z/

  @spec provider_id() :: atom()
  def provider_id, do: Provider.provider_id()

  @doc "Registers the narrow profile through ReqLLM's public provider registry."
  @spec register() :: :ok | {:error, Error.t()}
  def register do
    with :ok <- check_boundary() do
      register_provider(ReqLLM.Providers.get(provider_id()))
    end
  end

  defp register_provider({:ok, Provider}), do: :ok
  defp register_provider({:ok, _other}), do: failure(:subscription_registration_conflict)

  defp register_provider({:error, _}) do
    case ReqLLM.Providers.register(Provider) do
      {:ok, _id} -> :ok
      {:error, _} -> failure(:subscription_registration_failed)
    end
  end

  @doc "Reports whether the installed ReqLLM has the supported safe streaming boundary."
  def boundary_supported?(module \\ ReqLLM.Streaming.Failure) do
    Code.ensure_loaded?(module) and function_exported?(module, :normalization_version, 0) and
      Function.capture(module, :normalization_version, 0).() == 1
  end

  @doc false
  def check_boundary do
    if boundary_supported?(), do: :ok, else: failure(:unsupported_req_llm_version)
  end

  @forbidden_fields ~w(background conversation max_output_tokens max_tool_calls metadata moderation multi_agent prompt prompt_cache_retention safety_identifier temperature top_logprobs top_p truncation user previous_response_id)
  @forbidden_options [
    :background,
    :conversation,
    :max_tokens,
    :max_completion_tokens,
    :max_output_tokens,
    :max_tool_calls,
    :openai_max_tool_calls,
    :metadata,
    :moderation,
    :multi_agent,
    :prompt,
    :prompt_cache_retention,
    :safety_identifier,
    :temperature,
    :top_logprobs,
    :openai_top_logprobs,
    :top_p,
    :truncation,
    :user,
    :previous_response_id,
    :modalities,
    :audio
  ]
  @web_tools ~w(web_search web_search_preview web_search_preview_2025_03_11)
  @message_parts ~w(input_text output_text text refusal input_image input_file)
  @replay_items ~w(reasoning compaction configuration_update)

  @spec options(term()) :: {:ok, keyword()} | {:error, Error.t()}
  def options(token) do
    if valid_token?(token) do
      {:ok,
       [
         auth_mode: :oauth,
         access_token: token,
         stream: true,
         stream_transport: :http,
         provider_options: [
           auth_mode: :oauth,
           access_token: token,
           store: false,
           openai_stream_transport: :sse
         ],
         on_finch_request: request_hook(token, []),
         stream_error_normalizer: &normalize_stream_error/2,
         max_retries: 0,
         telemetry: [payloads: :none]
       ]}
    else
      failure(:access_token_missing)
    end
  end

  @spec subscription?(keyword()) :: boolean()
  def subscription?(opts) when is_list(opts) do
    case Keyword.get(opts, :on_finch_request) do
      hook when is_function(hook, 1) -> :erlang.fun_info(hook, :module) == {:module, __MODULE__}
      _ -> false
    end
  end

  def subscription?(_), do: false

  @doc "Validates explicit request preferences before Jido adds its generic defaults."
  @spec validate_options(keyword() | map()) :: :ok | {:error, Error.t()}
  def validate_options(opts), do: validate_options(opts, [])

  @doc "Rejects unsupported original media before the Responses encoder can omit it."
  @spec validate_context(ReqLLM.Context.prompt()) :: :ok | {:error, Error.t()}
  def validate_context(%ReqLLM.Context{messages: messages}) do
    if Enum.all?(messages, &valid_context_message?/1),
      do: :ok,
      else: failure(:subscription_sharing_unsupported_capability)
  end

  def validate_context(prompt) do
    case ReqLLM.Context.normalize(prompt) do
      {:ok, context} -> validate_context(context)
      {:error, _} -> failure(:subscription_sharing_unsupported_capability)
    end
  end

  @spec configure(term(), keyword(), keyword()) ::
          {:ok, {LLMDB.Model.t(), keyword()}} | {:error, Error.t()}
  def configure(model_input, opts, config \\ []) do
    generated = Keyword.get(config, :generated_options, [])

    with :ok <- validate_options(opts, generated),
         :ok <- register(),
         {:ok, model} <- ReqLLM.model(model_input),
         true <- model.provider in [:openai, provider_id()],
         true <- subscription?(opts),
         token = Keyword.get(opts, :access_token),
         {:ok, credentials} <- options(token),
         {:ok, provider_opts} <- provider_options(Keyword.get(opts, :provider_options, [])),
         {preserved, extra} <- split_tools(Keyword.get(opts, :tools, [])) do
      extra_metadata = responses_metadata(model.extra || %{})

      limits = model.limits |> then(&(&1 || %{})) |> Map.delete(:output) |> Map.delete("output")
      model = %{model | provider: provider_id(), extra: extra_metadata, limits: limits}

      provider_opts =
        provider_opts
        |> Keyword.merge(credentials[:provider_options])
        |> Keyword.delete(:previous_response_id)
        |> Keyword.delete(:oauth_file)
        |> Keyword.delete(:auth_file)

      configured =
        opts
        |> Keyword.merge(credentials)
        |> Keyword.put(:provider_options, provider_opts)
        |> Keyword.put(:on_finch_request, request_hook(token, extra))
        |> Keyword.put(:tools, preserved)
        |> Keyword.put(:base_url, @base_url)

      {:ok, {model, configured}}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:subscription_configuration_invalid)
    end
  end

  defp responses_metadata(extra) do
    wire =
      extra |> native_wire() |> Map.delete("protocol") |> Map.put(:protocol, "openai_responses")

    extra |> Map.delete("wire") |> Map.put(:wire, wire)
  end

  defp native_wire(%{wire: wire}) when wire not in [nil, false], do: wire
  defp native_wire(%{"wire" => wire}) when wire not in [nil, false], do: wire
  defp native_wire(_extra), do: %{}

  @doc "Shapes a body already encoded by the installed Responses API encoder."
  @spec profile_body(map()) :: {:ok, map()} | {:error, Error.t()}
  def profile_body(%{"input" => input} = body) when is_list(input) do
    with {:ok, tools} <- body_tools(Map.get(body, "tools", [])),
         :ok <- validate_input(input) do
      {additional, top_level} = Enum.split_with(tools, &(&1["type"] in ["function", "custom"]))
      input = Enum.map(input, &developer_message/1)

      input =
        if additional == [] do
          input
        else
          [%{"type" => "additional_tools", "role" => "developer", "tools" => additional} | input]
        end

      body =
        body
        |> Map.drop(@forbidden_fields)
        |> Map.put("input", input)
        |> Map.put("store", false)
        |> Map.put("stream", true)

      body =
        if top_level == [], do: Map.delete(body, "tools"), else: Map.put(body, "tools", top_level)

      {:ok, body}
    end
  end

  def profile_body(_), do: failure(:subscription_sharing_unsupported_capability)

  @doc "Classifies an installed Responses decoder chunk without retaining diagnostic text."
  @spec classify_chunk(ReqLLM.StreamChunk.t()) :: :continue | :completed | {:error, Error.t()}
  def classify_chunk(%ReqLLM.StreamChunk{type: :meta, metadata: %{terminal?: true} = metadata}) do
    status = response_status(metadata)

    case metadata[:error] do
      %Error{} = error -> {:error, Error.safe(error)}
      _other -> classify_terminal(metadata, status)
    end
  end

  def classify_chunk(%ReqLLM.StreamChunk{}), do: :continue

  defp classify_terminal(%{error_code: code} = metadata, _status) when is_binary(code) do
    {:error,
     Error.from_response(
       metadata[:http_status],
       %{"error" => %{"code" => code}},
       request_headers(metadata)
     )}
  end

  defp classify_terminal(metadata, status) do
    cond do
      status == "incomplete" ->
        failure(:stream_incomplete)

      status == "cancelled" ->
        failure(:stream_cancelled)

      Map.has_key?(metadata, :error) or status == "failed" ->
        {:error, Error.new(:provider_error)}

      status == "completed" and metadata[:finish_reason] in [:stop, :tool_calls, :content_filter] ->
        :completed

      true ->
        failure(:stream_incomplete)
    end
  end

  @doc "Projects HTTP or ReqLLM failure metadata to the safe authentication error contract."
  @spec classify_error(term()) :: Error.t()
  def classify_error(%Error{} = error), do: Error.safe(error)

  def classify_error(error) when is_map(error) do
    status = Map.get(error, :status) || Map.get(error, :status_code)
    body = Map.get(error, :body) || Map.get(error, :response_body) || %{}
    headers = Map.get(error, :headers) || Map.get(error, :response_headers) || %{}
    code = Map.get(error, :provider_code) || Map.get(error, :error_code)
    body = decode_error_body(body)

    body =
      if is_binary(code),
        do: Map.put_new(if(is_map(body), do: body, else: %{}), "code", code),
        else: body

    Error.from_response(status, body, headers)
  end

  def classify_error(_), do: Error.new(:provider_error)

  @doc """
  Shared request-scoped safe error projection for subscription and metered turns.

  Only observed HTTP metadata and allowlisted machine diagnostics survive.
  Provider identity comes from the selected model, never from a raw exception.
  """
  @spec normalize_stream_error(term(), LLMDB.Model.t()) :: Error.t() | :cancelled
  def normalize_stream_error(%ReqLLM.Error.API.Request{cause: %Error{} = safe} = http, model) do
    headers = Error.from_response(http.status, %{}, http.headers || %{})
    attrs = safe |> Error.safe() |> Map.from_struct()

    attrs =
      Map.merge(attrs, %{
        status: http.status || safe.status,
        request_id: headers.request_id || safe.request_id,
        retry_after: headers.retry_after || safe.retry_after,
        provider: diagnostic_provider(model)
      })

    Error.new(safe.code, attrs)
  end

  def normalize_stream_error(%{cause: %Error{} = error}, model),
    do: normalize_stream_error(error, model)

  def normalize_stream_error(%Error{} = error, model) do
    %{Error.safe(error) | provider: diagnostic_provider(model)}
  end

  def normalize_stream_error(reason, model) do
    case ReqLLM.Streaming.Failure.classify(reason) do
      :cancelled ->
        :cancelled

      {:transport, _reason, retryable} ->
        Error.new(:provider_unavailable, %{
          provider: diagnostic_provider(model),
          retryable: retryable
        })

      _ ->
        %{classify_error(reason) | provider: diagnostic_provider(model)}
    end
  end

  defp diagnostic_provider(%LLMDB.Model{provider: provider}) do
    if provider == provider_id(), do: :openai, else: provider
  end

  defp validate_options(opts, generated) when is_map(opts),
    do: validate_options(Map.to_list(opts), generated)

  defp validate_options(opts, generated) when is_list(opts) and is_list(generated) do
    with true <- Keyword.keyword?(opts) and Keyword.keyword?(generated),
         {:ok, provider_opts} <- provider_options(Keyword.get(opts, :provider_options, [])),
         :ok <- validate_preferences(opts, generated),
         :ok <-
           validate_preferences(provider_opts, Keyword.take(generated, [:previous_response_id])),
         :ok <- validate_http_options(Keyword.get(opts, :req_http_options, [])),
         :ok <- validate_option_tools(Keyword.get(opts, :tools, [])) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:subscription_configuration_invalid)
    end
  end

  defp validate_options(_, _), do: failure(:subscription_configuration_invalid)

  defp valid_context_message?(%ReqLLM.Message{content: parts, role: role, metadata: metadata}) do
    valid_parts =
      Enum.all?(parts, fn
        %ReqLLM.Message.ContentPart{type: type, media_type: media}
        when type in [:text, :image, :image_url, :file] ->
          not (is_binary(media) and String.starts_with?(media, ["audio/", "video/"]))

        %ReqLLM.Message.ContentPart{type: :thinking} ->
          role == :assistant

        %ReqLLM.Message.ContentPart{
          type: :provider_block,
          metadata: %{provider: :openai, block_type: "compaction"}
        } ->
          role == :assistant

        _ ->
          false
      end)

    case Map.get(metadata, :responses_replay) do
      %{provider: :openai, items: items} when is_list(items) ->
        valid_parts and Enum.all?(items, &valid_input_item?/1)

      nil ->
        valid_parts

      _ ->
        false
    end
  end

  defp valid_context_message?(_), do: false
  defp validate_option_tools(nil), do: :ok

  defp validate_option_tools(tools) when is_list(tools) do
    valid =
      Enum.all?(tools, fn
        %ReqLLM.Tool{name: name} ->
          is_binary(name) and name != ""

        tool ->
          case normalize_tool(tool) do
            {:ok, %{"type" => "custom"}} ->
              false

            {:ok, %{"type" => "namespace", "tools" => members}} ->
              Enum.all?(members, &(&1["type"] == "function"))

            {:ok, _tool} ->
              true

            {:error, _error} ->
              false
          end
      end)

    if valid, do: :ok, else: failure(:subscription_sharing_unsupported_capability)
  end

  defp validate_option_tools(_), do: failure(:subscription_sharing_unsupported_capability)

  defp validate_preferences(opts, generated) do
    with :ok <- validate_forbidden_preferences(opts, generated),
         :ok <- validate_auth_preferences(opts),
         :ok <- validate_stateless_preferences(opts),
         :ok <- validate_transport_preferences(opts) do
      if raw_telemetry?(Keyword.get(opts, :telemetry, [])),
        do: failure(:unsafe_telemetry),
        else: :ok
    end
  end

  defp validate_forbidden_preferences(opts, generated) do
    forbidden? =
      Enum.any?(@forbidden_options, fn key ->
        Keyword.has_key?(opts, key) and Keyword.get(opts, key) != nil and
          not generated_option?(key, opts, generated)
      end)

    if forbidden?,
      do: failure(:subscription_sharing_unsupported_capability),
      else: :ok
  end

  defp validate_auth_preferences(opts) do
    cond do
      Keyword.get(opts, :api_key) != nil ->
        failure(:billing_mode_conflict)

      Keyword.get(opts, :oauth_file) != nil or Keyword.get(opts, :auth_file) != nil ->
        failure(:credential_file_unsupported)

      Keyword.has_key?(opts, :base_url) and Keyword.get(opts, :base_url) != @base_url ->
        failure(:subscription_route_invalid)

      Keyword.has_key?(opts, :auth_mode) and Keyword.get(opts, :auth_mode) != :oauth ->
        failure(:billing_mode_conflict)

      true ->
        :ok
    end
  end

  defp validate_stateless_preferences(opts) do
    cond do
      Keyword.has_key?(opts, :store) and Keyword.get(opts, :store) != false ->
        failure(:subscription_sharing_unsupported_capability)

      Keyword.has_key?(opts, :stream) and Keyword.get(opts, :stream) != true ->
        failure(:subscription_sharing_unsupported_capability)

      Keyword.has_key?(opts, :stream_transport) and
          Keyword.get(opts, :stream_transport) not in [:http, :sse] ->
        failure(:subscription_sharing_unsupported_capability)

      true ->
        :ok
    end
  end

  defp validate_transport_preferences(opts) do
    cond do
      Keyword.has_key?(opts, :openai_stream_transport) and
          Keyword.get(opts, :openai_stream_transport) != :sse ->
        failure(:subscription_sharing_unsupported_capability)

      Keyword.get(opts, :openai_reuse_websocket, false) != false or
          Keyword.get(opts, :openai_websocket_session) != nil ->
        failure(:subscription_sharing_unsupported_capability)

      Keyword.has_key?(opts, :max_retries) and Keyword.get(opts, :max_retries) != 0 ->
        failure(:subscription_sharing_unsupported_capability)

      true ->
        :ok
    end
  end

  defp generated_option?(key, opts, generated) do
    key in [:max_tokens, :temperature, :previous_response_id] and Keyword.has_key?(generated, key) and
      Keyword.get(opts, key) == Keyword.get(generated, key)
  end

  defp provider_options(opts) when is_map(opts) do
    provider_options(Enum.map(opts, fn {key, value} -> {existing_option_key(key), value} end))
  end

  defp provider_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.pop(opts, :openai) do
        {nil, flat} -> {:ok, flat}
        {nested, []} -> provider_options(nested)
        _ -> failure(:subscription_configuration_invalid)
      end
    else
      failure(:subscription_configuration_invalid)
    end
  end

  defp provider_options(_), do: failure(:subscription_configuration_invalid)
  defp existing_option_key(key) when is_atom(key), do: key

  defp existing_option_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_option_key(_), do: nil

  defp validate_http_options(opts) when is_map(opts), do: validate_http_options(Map.to_list(opts))

  defp validate_http_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and not Keyword.has_key?(opts, :auth) and
         not Enum.any?(Keyword.get(opts, :headers, []), &authorization_header?/1) do
      :ok
    else
      failure(:billing_mode_conflict)
    end
  end

  defp validate_http_options(_), do: failure(:subscription_configuration_invalid)

  defp authorization_header?({key, _}) when is_binary(key),
    do: String.downcase(key) == "authorization"

  defp authorization_header?({:authorization, _}), do: true
  defp authorization_header?(_), do: false
  defp raw_telemetry?(opts) when is_list(opts), do: Keyword.get(opts, :payloads) == :raw

  defp raw_telemetry?(opts) when is_map(opts),
    do: Map.get(opts, :payloads, Map.get(opts, "payloads")) in [:raw, "raw"]

  defp raw_telemetry?(_), do: false

  defp body_tools(nil), do: {:ok, []}

  defp body_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case normalize_tool(tool) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      error -> error
    end
  end

  defp body_tools(_), do: failure(:subscription_sharing_unsupported_capability)

  defp normalize_tool(%ReqLLM.Tool{} = tool) do
    schema = ReqLLM.Tool.to_schema(tool)["function"]
    normalize_tool(Map.put(schema, "type", "function"))
  end

  defp normalize_tool(tool) when is_map(tool) do
    tool = stringify_tool(tool)
    type = tool["type"] || if(is_map(tool["function"]), do: "function")

    normalize_tool_type(tool, type)
  end

  defp normalize_tool(_), do: failure(:subscription_sharing_unsupported_capability)

  defp normalize_tool_type(tool, type) when type in ["function", "custom"] do
    tool =
      if is_map(tool["function"]),
        do: Map.put(tool["function"], "type", "function"),
        else: tool

    if is_binary(tool["name"]) and tool["name"] != "",
      do: {:ok, tool},
      else: failure(:subscription_sharing_unsupported_capability)
  end

  defp normalize_tool_type(tool, "namespace") do
    with true <-
           is_binary(tool["name"]) and tool["name"] != "" and is_binary(tool["description"]),
         {:ok, members} <- body_tools(tool["tools"]),
         true <- members != [] and Enum.all?(members, &(&1["type"] in ["function", "custom"])) do
      {:ok, Map.put(tool, "tools", members)}
    else
      _ -> failure(:subscription_sharing_unsupported_capability)
    end
  end

  defp normalize_tool_type(tool, type) when type in @web_tools, do: {:ok, tool}

  defp normalize_tool_type(_tool, _type),
    do: failure(:subscription_sharing_unsupported_capability)

  defp stringify_tool(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      value = if key == "type" and is_atom(value), do: Atom.to_string(value), else: value
      value = if key == "function" and is_map(value), do: stringify_tool(value), else: value
      {key, value}
    end)
  end

  defp split_tools(nil), do: {[], []}

  defp split_tools(tools) do
    {extra, preserved} = Enum.split_with(tools, &additional_tool?/1)

    {preserved, Enum.map(extra, &stringify_tool/1)}
  end

  defp additional_tool?(%ReqLLM.Tool{}), do: false

  defp additional_tool?(tool) when is_map(tool),
    do: native_tool_type(tool) in [:namespace, "namespace", :custom, "custom"]

  defp native_tool_type(%{type: type}) when type not in [nil, false], do: type
  defp native_tool_type(%{"type" => type}), do: type
  defp native_tool_type(_tool), do: nil

  defp validate_input(input) do
    if Enum.all?(input, &valid_input_item?/1),
      do: :ok,
      else: failure(:subscription_sharing_unsupported_capability)
  end

  defp valid_input_item?(%{"type" => "additional_tools", "role" => "developer", "tools" => tools}) do
    match?({:ok, _}, body_tools(tools))
  end

  defp valid_input_item?(%{"type" => type} = item)
       when type in ["function_call", "custom_tool_call"] do
    is_binary(item["call_id"]) and is_binary(item["name"]) and
      is_binary(item[if(type == "function_call", do: "arguments", else: "input")])
  end

  defp valid_input_item?(%{"type" => type} = item)
       when type in ["function_call_output", "custom_tool_call_output"] do
    is_binary(item["call_id"]) and valid_content?(item["output"])
  end

  defp valid_input_item?(%{"type" => type}) when type in @replay_items, do: true

  defp valid_input_item?(%{"role" => role, "content" => content} = item) do
    role in ["system", "developer", "user", "assistant"] and
      Map.get(item, "type", "message") == "message" and valid_content?(content)
  end

  defp valid_input_item?(_), do: false
  defp valid_content?(content) when is_binary(content), do: true

  defp valid_content?(content) when is_list(content),
    do: Enum.all?(content, &(is_map(&1) and &1["type"] in @message_parts))

  defp valid_content?(_), do: false
  defp developer_message(%{"role" => "system"} = item), do: Map.put(item, "role", "developer")
  defp developer_message(item), do: item

  defp request_hook(token, extra_tools) do
    fn request -> profile_request(request, token, extra_tools) end
  end

  defp profile_request(
         %Finch.Request{
           method: "POST",
           scheme: :https,
           host: "api.openai.com",
           port: 443,
           path: "/v1/responses",
           query: nil,
           unix_socket: nil
         } = request,
         token,
         extra_tools
       ) do
    authorization = Enum.filter(request.headers, &authorization_header?/1)

    with [{_, expected}] <- authorization,
         true <- expected == "Bearer " <> token,
         {:ok, body} when is_map(body) <- Jason.decode(IO.iodata_to_binary(request.body)),
         body =
           if(extra_tools == [],
             do: body,
             else: Map.update(body, "tools", extra_tools, &(&1 ++ extra_tools))
           ),
         {:ok, body} <- profile_body(body) do
      %{request | body: body |> ReqLLM.Schema.apply_property_ordering() |> Jason.encode!()}
    else
      {:error, %Error{} = error} -> raise error
      _ -> raise Error.new(:subscription_request_invalid)
    end
  end

  defp profile_request(_, _, _), do: raise(Error.new(:subscription_route_invalid))

  defp request_headers(metadata) do
    if metadata[:request_id], do: %{"x-request-id" => metadata.request_id}, else: %{}
  end

  defp response_status(metadata) do
    case metadata[:provider_meta] do
      provider_meta when is_map(provider_meta) ->
        provider_meta |> normalize_provider_meta() |> Map.get("status")

      _ ->
        nil
    end
  end

  defp normalize_provider_meta(%{status: status} = metadata) do
    metadata
    |> Map.delete(:status)
    |> Map.update("status", status, &(&1 || status))
  end

  defp normalize_provider_meta(metadata), do: metadata

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_error_body(body), do: body

  defp valid_token?(token),
    do:
      is_binary(token) and byte_size(token) in 1..65_536 and Regex.match?(@bearer_pattern, token)

  defp failure(code), do: {:error, Error.new(code)}
end

defmodule OhMyJido.Models.Subscription.Provider do
  @moduledoc """
  ReqLLM policy adapter for documented SIWC subscription requests.

  OpenAI owns request planning, encoding, Finch HTTP, SSE parsing, stateful
  Responses decoding and successful response construction. This adapter changes
  only the registered provider identity and terminal metadata; it never performs
  model HTTP, credential refresh, or a model loop.
  """

  @behaviour ReqLLM.Provider

  alias OhMyJido.Auth.Error
  alias OhMyJido.Models.Subscription
  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  def provider_id, do: :oh_my_jido_openai_subscription
  def default_base_url, do: OpenAI.default_base_url()
  def base_url, do: OpenAI.base_url()
  defdelegate provider_schema(), to: OpenAI
  defdelegate supported_provider_options(), to: OpenAI
  defdelegate provider_extended_generation_schema(), to: OpenAI

  @impl ReqLLM.Provider
  def prepare_request(_operation, _model, _prompt, _opts),
    do: {:error, Error.new(:subscription_stream_required)}

  @impl ReqLLM.Provider
  def attach(request, model, opts), do: OpenAI.attach(request, native_model(model), opts)

  @impl ReqLLM.Provider
  defdelegate encode_body(request), to: ResponsesAPI

  @impl ReqLLM.Provider
  defdelegate build_body(request), to: ResponsesAPI

  @impl ReqLLM.Provider
  defdelegate decode_response(pair), to: OpenAI

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts),
    do: OpenAI.translate_options(operation, native_model(model), opts)

  @impl ReqLLM.Provider
  def stream_transport(_model, _opts), do: :http

  @impl ReqLLM.Provider
  defdelegate normalize_stream_error(reason, model), to: Subscription

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    with :ok <- Subscription.check_boundary(),
         true <- Subscription.subscription?(opts),
         true <-
           opts[:auth_mode] == :oauth and is_binary(opts[:access_token]) and
             opts[:access_token] != "",
         true <- opts[:api_key] == nil and opts[:oauth_file] == nil and opts[:auth_file] == nil,
         true <- opts[:base_url] == OpenAI.base_url(),
         :ok <- Subscription.validate_context(context) do
      OpenAI.attach_stream(native_model(model), context, opts, finch_name)
    else
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:subscription_configuration_invalid)}
    end
  end

  @impl ReqLLM.Provider
  defdelegate parse_stream_protocol(chunk, state), to: ReqLLM.Provider

  @impl ReqLLM.Provider
  def init_stream_state(_model),
    do: %{decoder: ResponsesAPI.init_stream_state(), terminal?: false}

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    {chunks, _state} = decode_stream_event(event, model, init_stream_state(model))
    chunks
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    state = state || init_stream_state(model)

    {chunks, decoder} =
      ResponsesAPI.decode_stream_event(event, native_model(model), state.decoder)

    terminal? = Enum.any?(chunks, &(&1.type == :meta and &1.metadata[:terminal?] == true))
    chunks = if terminal?, do: Enum.map(chunks, &safe_terminal(&1, event)), else: chunks
    {chunks, %{state | decoder: decoder, terminal?: state.terminal? or terminal?}}
  end

  @impl ReqLLM.Provider
  def flush_stream_state(_model, %{terminal?: true} = state), do: {[], state}

  def flush_stream_state(model, state) do
    state = state || init_stream_state(model)
    error = Error.new(:stream_interrupted)

    chunk =
      ReqLLM.StreamChunk.meta(%{
        terminal?: true,
        finish_reason: :error,
        error: error,
        error_code: Atom.to_string(error.code)
      })

    {[chunk], %{state | terminal?: true}}
  end

  defp safe_terminal(
         %ReqLLM.StreamChunk{type: :meta, metadata: %{terminal?: true} = metadata} = chunk,
         event
       ) do
    case Subscription.classify_chunk(chunk) do
      :completed ->
        chunk

      {:error, error} ->
        error =
          if is_binary(metadata[:error_code]),
            do:
              Error.from_response(
                metadata[:http_status],
                event_error_body(event),
                event_headers(event)
              ),
            else: error

        metadata =
          metadata
          |> Map.put(:error, error)
          |> Map.put(:error_code, Atom.to_string(error.code))
          |> Map.put(:finish_reason, :error)
          |> Map.update(:provider_meta, %{}, fn provider_meta ->
            Map.take(provider_meta, ["status"])
          end)

        %{chunk | metadata: metadata}
    end
  end

  defp safe_terminal(chunk, _event), do: chunk

  defp event_error_body(%{data: %{"response" => response}}) when is_map(response), do: response
  defp event_error_body(%{data: data}) when is_map(data), do: data
  defp event_error_body(_), do: %{}

  defp event_headers(%{data: %{"request_id" => request_id}}), do: %{"x-request-id" => request_id}
  defp event_headers(_), do: %{}
  defp native_model(%LLMDB.Model{} = model), do: %{model | provider: :openai}
end
