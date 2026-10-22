defmodule OhMyJido.Extensions.MCP do
  @moduledoc """
  Scoped reference MCP stdio adapter, using the installed JSON codec.

  The host configures the external server command and exact `tools` and
  `resources` allowlists; neither server announcements nor model input grants
  authority. Sampling, elicitation, reverse tool execution and implicit roots
  are not advertised. Server text is returned as untrusted content.
  """

  alias OhMyJido.Intelligence.Stdio
  alias OhMyJido.Tool

  @versions ["2025-06-18", "2025-03-26", "2024-11-05"]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 15_000
    }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Stdio.start_link(Keyword.put(opts, :protocol, :mcp))

  @spec invoke(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(context, %{operation: :close}, opts), do: close(context, opts)

  def invoke(context, request, opts) do
    with :ok <- scope(request, opts),
         server when not is_nil(server) <- Keyword.get(opts, :server),
         {:ok, identity} <- Stdio.bind(server, context),
         {:ok, result} <- execute(server, request, opts),
         :ok <- bounded(context, result) do
      {:ok, %{result: result, identity: identity, trusted: false}}
    else
      nil -> {:error, {:capability_unavailable, :mcp}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Closes the session's MCP server, given as the trusted `:server` option, at session teardown.

  Returns `:ok` once cleanup of the owned server process group is confirmed or the
  server is already closed, and `{:error, reason}` otherwise.
  """
  @spec close_session(map(), keyword()) :: :ok | {:error, term()}
  defdelegate close_session(context, opts), to: Stdio

  @spec close(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(context, opts) do
    with server when not is_nil(server) <- Keyword.get(opts, :server),
         {:ok, _identity} <- Stdio.bind(server, context) do
      Stdio.close(server, context)
    else
      nil -> {:error, {:capability_unavailable, :mcp}}
      {:error, _} = error -> error
    end
  end

  defp execute(server, %{operation: :initialize}, opts) do
    version = Keyword.get(opts, :protocol_version, hd(@versions))

    with true <- version in @versions,
         {:ok, result} <-
           Stdio.request(server, "initialize", %{
             "protocolVersion" => version,
             "capabilities" => %{},
             "clientInfo" => %{"name" => "oh_my_jido", "version" => "0.1"}
           }),
         true <- result["protocolVersion"] in @versions,
         :ok <- Stdio.notify(server, "notifications/initialized", %{}) do
      {:ok, result}
    else
      false -> {:error, :mcp_protocol_version_unsupported}
      {:error, _} = error -> error
    end
  end

  defp execute(server, %{operation: :list_tools} = request, opts) do
    with {:ok, %{"tools" => tools} = result} when is_list(tools) <-
           Stdio.request(server, "tools/list", cursor(request)),
         true <-
           Enum.all?(tools, fn
             %{"name" => name} -> is_binary(name)
             _ -> false
           end) do
      tools = Enum.filter(tools, &granted?(Keyword.get(opts, :tools, []), &1["name"]))
      {:ok, Map.put(result, "tools", tools)}
    else
      {:ok, _invalid} -> {:error, :invalid_mcp_tool_list}
      false -> {:error, :invalid_mcp_tool_list}
      {:error, _} = error -> error
    end
  end

  defp execute(server, %{operation: :list_resources} = request, opts) do
    with {:ok, result} <- Stdio.request(server, "resources/list", cursor(request)) do
      resources =
        Map.get(result, "resources", [])
        |> Enum.filter(&granted?(Keyword.get(opts, :resources, []), &1["uri"]))

      {:ok, Map.put(result, "resources", resources)}
    end
  end

  defp execute(server, %{operation: :call_tool, name: name} = request, _opts) do
    case Stdio.request(server, "tools/call", %{
           "name" => name,
           "arguments" => Map.get(request, :arguments, %{})
         }) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, %{reason: :mcp_tool_outcome_unknown, cause: reason, effect: :uncertain}}
    end
  end

  defp execute(server, %{operation: :read_resource, uri: uri}, _opts),
    do: Stdio.request(server, "resources/read", %{"uri" => uri})

  defp execute(_server, _request, _opts), do: {:error, :unsupported_mcp_operation}

  defp scope(%{operation: :call_tool, name: name}, opts) do
    if granted?(Keyword.get(opts, :tools, []), name),
      do: :ok,
      else: {:error, {:mcp_tool_not_granted, name}}
  end

  defp scope(%{operation: :read_resource, uri: uri}, opts) do
    if granted?(Keyword.get(opts, :resources, []), uri),
      do: :ok,
      else: {:error, {:mcp_resource_not_granted, uri}}
  end

  defp scope(_request, _opts), do: :ok

  defp granted?(%MapSet{} = values, value), do: MapSet.member?(values, value)
  defp granted?(values, value) when is_list(values), do: value in values
  defp granted?(_values, _value), do: false
  defp cursor(%{cursor: cursor}) when is_binary(cursor), do: %{"cursor" => cursor}
  defp cursor(_request), do: %{}

  @doc false
  @spec bounded(map(), term()) :: :ok | {:error, term()}
  def bounded(context, result) do
    maximum = Map.get(context.limits, :extension_result_bytes, 65_536)

    case Jason.encode_to_iodata(result) do
      {:ok, encoded} ->
        if IO.iodata_length(encoded) <= maximum,
          do: :ok,
          else:
            {:error,
             %{
               reason: :mcp_result_limit,
               limit: maximum,
               effect: :completed,
               result: :unavailable
             }}

      {:error, _} ->
        {:error, :invalid_mcp_result}
    end
  end

  @doc "Exercises a real scoped MCP tool and resource only on explicit human invocation."
  @spec smoke(map(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def smoke(context, server_opts, plan) do
    with :ok <-
           Tool.authorize(context, :mcp, %{
             operation: :real_server_smoke,
             tool: plan.name,
             resource: plan.resource,
             sensitive: true
           }),
         {:ok, server} <-
           Stdio.start(
             Keyword.merge(server_opts, context: context, owner: self(), protocol: :mcp)
           ) do
      opts = Keyword.put(server_opts, :server, server)

      try do
        with {:ok, initialized} <- invoke(context, %{operation: :initialize}, opts),
             {:ok, tool} <-
               invoke(
                 context,
                 %{operation: :call_tool, name: plan.name, arguments: plan.arguments},
                 opts
               ),
             :ok <- expected_text(tool.result, "content", plan.expected_text),
             {:ok, resource} <-
               invoke(context, %{operation: :read_resource, uri: plan.resource}, opts),
             :ok <- expected_text(resource.result, "contents", plan.expected_resource_text) do
          {:ok, %{initialized: initialized, tool: tool, resource: resource}}
        end
      after
        close_session(context, opts)
      end
    end
  end

  defp expected_text(result, field, expected) do
    entries = Map.get(result, field, [])

    if Enum.any?(entries, &(Map.get(&1, "text") == expected)),
      do: :ok,
      else: {:error, {:mcp_smoke_result_mismatch, field}}
  end
end
