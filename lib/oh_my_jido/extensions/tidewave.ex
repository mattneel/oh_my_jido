defmodule OhMyJido.Extensions.Tidewave do
  @moduledoc """
  Host-pinned binding to the native Tidewave stdio proxy through scoped MCP.

  Start the existing `OhMyJido.Extensions.MCP` owner with the host-selected
  `mix tidewave.proxy --no-browser-tools` command, then bind this adapter under
  `context.adapters.mcp` with `server: pid`, `port: integer` and an explicit
  `tools` allowlist. Tidewave is installed in that external application, not
  added as a dependency of this library. The loopback port cannot be supplied
  by a tool request: it is hidden from discovery and injected from host options.

  Only `get_logs` is exempt from the additional runtime authority. Native source
  lookups (`get_docs` and `get_source_location`) can allocate permanent atoms and
  load modules, including `@on_load`; they also require `:live_eval` and sensitive
  authorization. Every other tool has the same additional requirement, with
  exact target/tool/argument digests and code digest when supplied. Approval
  effects contain no raw code/arguments; discovery never grants authority.

  Live execution is a last resort after structured Observer, docs and logs.
  Native `project_eval` (including explicitly approved RPC) is intended for an
  external application VM. The host must bind that separate target; this is not
  the isolated Eval sandbox or permission to evaluate in the library host.
  No fallback, retry, transport or evaluation engine is implemented here.
  Result identity, untrusted content and uncertain-effect errors remain MCP's.
  """

  alias OhMyJido.{Context, Tool}
  alias OhMyJido.Extensions.MCP

  @inspection ~w(get_logs)
  @native_source ~w(get_docs get_source_location)
  @selectors ~w(port target host hostname url endpoint base_url node cookie server)
  @selector_atoms Enum.map(@selectors, &String.to_atom/1)
  @request_keys %{
    initialize: [:operation],
    list_tools: [:operation, :cursor],
    call_tool: [:operation, :name, :arguments],
    list_resources: [:operation, :cursor],
    read_resource: [:operation, :uri],
    close: [:operation]
  }
  @live_description "Last resort: prefer structured Observer, docs, source locations or logs. " <>
                      "This tool may affect the approved live application; it is not isolated Eval. "
  @source_description "Native source inspection may allocate atoms and load modules, including " <>
                        "@on_load callbacks. Requires explicit live runtime approval. "

  @spec invoke(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(execution_context, request, opts) do
    with {:ok, port} <- trusted_port(opts),
         :ok <- trusted_server(opts),
         :ok <- explicit_allowlist(opts),
         {:ok, context} <- Context.fetch(execution_context),
         {:ok, request} <- pin(request, port),
         :ok <- scope(request, opts),
         :ok <- bounded_input(context, request),
         target = "http://127.0.0.1:#{port}/tidewave/mcp",
         :ok <- Tool.authorize(context, :mcp, mcp_effect(request, target)),
         :ok <- authorize_live(context, request, target),
         {:ok, response} <- MCP.invoke(context, request, opts),
         {:ok, response} <- present(context, request, response, opts),
         response = Map.merge(response, %{target: target, mode: :live, trusted: false}),
         :ok <- MCP.bounded(context, response) do
      {:ok, response}
    end
  end

  @doc "Closes only the bound session's MCP owner, including after grants are revoked."
  @spec close_session(map(), keyword()) :: :ok | {:error, term()}
  def close_session(execution_context, opts) do
    with {:ok, _port} <- trusted_port(opts),
         :ok <- trusted_server(opts),
         {:ok, context} <- Context.fetch(execution_context) do
      MCP.close_session(context, opts)
    end
  end

  defp trusted_port(opts) do
    case Keyword.get(opts, :port) do
      port when is_integer(port) and port in 1..65_535 -> {:ok, port}
      _invalid -> {:error, :invalid_tidewave_port}
    end
  end

  defp trusted_server(opts) do
    case Keyword.get(opts, :server) do
      server when is_pid(server) -> :ok
      nil -> {:error, {:capability_unavailable, :mcp}}
      _invalid -> {:error, :invalid_tidewave_server}
    end
  end

  defp explicit_allowlist(opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, %MapSet{} = tools} -> valid_allowlist(MapSet.to_list(tools))
      {:ok, tools} when is_list(tools) -> valid_allowlist(tools)
      _invalid -> {:error, :tidewave_tools_allowlist_required}
    end
  end

  defp valid_allowlist(tools) do
    if Enum.all?(tools, &valid_text?(&1, 256)),
      do: :ok,
      else: {:error, :invalid_tidewave_tools_allowlist}
  end

  defp pin(%{operation: operation} = request, port) do
    with :ok <- no_target_selectors(request),
         {:ok, keys} <- request_keys(operation),
         true <- Enum.all?(Map.keys(request), &(&1 in keys)),
         :ok <- selectors(request) do
      pin_arguments(request, port)
    else
      false -> {:error, :invalid_tidewave_request}
      {:error, _} = error -> error
    end
  end

  defp pin(_request, _port), do: {:error, :invalid_tidewave_request}

  defp request_keys(operation) do
    case Map.fetch(@request_keys, operation) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, :unsupported_mcp_operation}
    end
  end

  defp selectors(%{operation: :call_tool, name: name}) do
    if valid_text?(name, 256), do: :ok, else: {:error, :invalid_mcp_selector}
  end

  defp selectors(%{operation: :call_tool}), do: {:error, :mcp_selector_required}

  defp selectors(%{operation: :read_resource, uri: uri}) do
    if valid_text?(uri, 8_192), do: :ok, else: {:error, :invalid_mcp_selector}
  end

  defp selectors(%{operation: :read_resource}), do: {:error, :mcp_selector_required}

  defp selectors(%{cursor: cursor}) do
    if valid_text?(cursor, 1_024), do: :ok, else: {:error, :invalid_mcp_selector}
  end

  defp selectors(_request), do: :ok

  defp pin_arguments(%{operation: :call_tool} = request, port) do
    case Map.get(request, :arguments, %{}) do
      arguments when is_map(arguments) and not is_struct(arguments) ->
        with :ok <- no_target_selectors(arguments),
             {:ok, arguments} <- string_keys(arguments) do
          {:ok, Map.put(request, :arguments, Map.put(arguments, "port", port))}
        end

      _invalid ->
        {:error, :invalid_mcp_arguments}
    end
  end

  defp pin_arguments(request, _port), do: {:ok, request}

  defp no_target_selectors(values) do
    if Enum.any?(Map.keys(values), &(&1 in @selectors or &1 in @selector_atoms)),
      do: {:error, :tidewave_target_selector_forbidden},
      else: :ok
  end

  defp string_keys(arguments) do
    Enum.reduce_while(arguments, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(key) and not Map.has_key?(result, key),
        do: {:cont, {:ok, Map.put(result, key, value)}},
        else: {:halt, {:error, :invalid_mcp_arguments}}
    end)
  end

  defp scope(%{operation: :call_tool, name: name}, opts) do
    if granted?(opts, name), do: :ok, else: {:error, {:mcp_tool_not_granted, name}}
  end

  defp scope(_request, _opts), do: :ok

  defp granted?(opts, name) do
    case Keyword.fetch!(opts, :tools) do
      %MapSet{} = tools -> MapSet.member?(tools, name)
      tools -> name in tools
    end
  end

  defp bounded_input(context, request) do
    limit = Map.get(context.limits, :extension_input_bytes, 32_768)

    case Jason.encode_to_iodata(request) do
      {:ok, bytes} ->
        if IO.iodata_length(bytes) <= limit, do: :ok, else: {:error, {:mcp_input_limit, limit}}

      {:error, _reason} ->
        {:error, :invalid_mcp_arguments}
    end
  end

  defp mcp_effect(request, target) do
    %{
      operation: request.operation,
      tool: Map.get(request, :name),
      resource: Map.get(request, :uri),
      target: target,
      mode: :live,
      sensitive: request.operation == :call_tool
    }
  end

  defp authorize_live(context, %{operation: :call_tool, name: name} = request, target)
       when name not in @inspection do
    effect = %{
      operation: :call_tool,
      tool: name,
      target: target,
      mode: :live,
      sensitive: true,
      arguments_sha256: digest(Jason.encode_to_iodata!(request.arguments)),
      intent: live_intent(name)
    }

    effect =
      case request.arguments do
        %{"code" => code} when is_binary(code) -> Map.put(effect, :code_sha256, digest(code))
        _arguments -> effect
      end

    Tool.authorize(context, :live_eval, effect)
  end

  defp authorize_live(_context, _request, _target), do: :ok

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp live_intent("project_eval"),
    do: "Evaluate explicitly approved code in the live application"

  defp live_intent(name) when name in @native_source,
    do: "Inspect source with explicit native atom/module-loading authority"

  defp live_intent(_name),
    do: "Invoke an explicitly approved non-inspection tool in the live application"

  defp present(context, %{operation: operation}, %{result: %{"tools" => tools}} = response, opts)
       when operation in [:initialize, :list_tools] and is_list(tools) do
    tools =
      Enum.filter(tools, fn tool ->
        is_map(tool) and granted?(opts, tool["name"]) and
          (tool["name"] in @inspection or Context.permitted?(context, :live_eval))
      end)

    with {:ok, tools} <- present_tools(tools) do
      {:ok, put_in(response, [:result, "tools"], tools)}
    end
  end

  defp present(_context, %{operation: :initialize}, %{result: %{"tools" => _invalid}}, _opts),
    do: {:error, :invalid_tidewave_tools_response}

  defp present(_context, %{operation: :list_tools}, _response, _opts),
    do: {:error, :invalid_tidewave_tools_response}

  defp present(_context, _request, response, _opts), do: {:ok, response}

  defp present_tools(tools) do
    Enum.reduce_while(tools, {:ok, []}, &present_tool/2)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      {:error, _} = error -> error
    end
  end

  defp present_tool(
         %{"inputSchema" => %{"properties" => properties} = schema} = tool,
         {:ok, result}
       )
       when is_map(properties) do
    case Map.get(schema, "required", []) do
      required when is_list(required) ->
        schema =
          schema
          |> Map.put("properties", Map.delete(properties, "port"))
          |> Map.put("required", Enum.reject(required, &(&1 == "port")))

        tool = tool |> Map.put("inputSchema", schema) |> describe_live()
        {:cont, {:ok, [tool | result]}}

      _invalid ->
        {:halt, {:error, :invalid_tidewave_tool_schema}}
    end
  end

  defp present_tool(_invalid, _acc), do: {:halt, {:error, :invalid_tidewave_tool_schema}}

  defp describe_live(%{"name" => name} = tool) when name in @inspection, do: tool

  defp describe_live(tool) do
    description = Map.get(tool, "description", "")
    suffix = if is_binary(description), do: description, else: ""
    prefix = if tool["name"] in @native_source, do: @source_description, else: @live_description

    annotations =
      case tool["annotations"] do
        value when is_map(value) -> value
        _ -> %{}
      end

    tool
    |> Map.put("description", prefix <> suffix)
    |> Map.put("annotations", Map.put(annotations, "readOnlyHint", false))
  end

  defp valid_text?(value, maximum) do
    is_binary(value) and value != "" and byte_size(value) <= maximum and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end
end
