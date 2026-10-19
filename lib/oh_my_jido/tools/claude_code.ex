defmodule OhMyJido.Tools.ClaudeCode do
  @moduledoc """
  Separate delegation to a user-authenticated, unmodified official Claude Code.

  The host explicitly attests `official_binary: true` and pins the executable's
  SHA-256 in adapter options. This checks bytes since host approval, not vendor
  provenance of an arbitrary download. The complete installed distribution and
  managed policy remain the host's responsibility. This integration requires the
  documented CLI flags `--restricted` and `--permission-prompts` (v2.1.259+).

  Authentication occurs only in Anthropic's own binary. Its `auth status` must
  report `claude.ai`; API-key, helper, imported OAuth-token and cloud-provider
  methods are rejected. No login is initiated and no credential files/tokens are
  read, imported or brokered by Oh-My-Jido. Metered/provider environment overrides
  are removed in each child, never globally.

  Delegation is not a native Jido subscription model or a bridge for Claude's
  tool calls into Jido. It has its own bounded CLI turn and permission behavior.
  It uses the official binary's current OS-user login, not `Context.account` or
  this library's OAuth vault; multi-user hosts must isolate that OS identity.
  Approved tools must also have corresponding Jido capability grants. The exact
  host-approved subset is supplied to the official CLI's permission allowlist;
  available tools alone do not authorize edits in manual mode. Administrator
  deny policy still applies; unanswered permission prompts are denied, not
  bypassed. Restricted mode and empty MCP configuration disable repository/user
  customizations and MCP; managed policy remains under the host's control.
  """
  use Jido.Action,
    name: "claude_code",
    description:
      "Delegate an explicitly approved task to the user's official Claude Code; this is a separate agent, not native Jido inference.",
    schema: Zoi.object(%{prompt: Zoi.string()})

  alias OhMyJido.{Context, Tool}

  @tool_capabilities %{
    "Read" => :read,
    "Glob" => :read,
    "Grep" => :read,
    "Edit" => :edit,
    "Write" => :edit,
    "Bash" => :exec
  }
  @removed_environment ~w(
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
    ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
    CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR
    CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
    CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_BEDROCK
    CLAUDE_CODE_FALLBACK_MODEL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    CLAUDE_CODE_SIMPLE CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD
  )

  def capability, do: :claude_code

  @impl true
  def run(request, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context) do
      case Map.get(context.adapters, capability()) do
        {__MODULE__, opts} -> invoke(context, request, opts)
        _unconfigured -> {:error, {:capability_unavailable, capability()}}
      end
    end
  end

  @doc "Host adapter entrypoint; executable, tools and model come only from trusted options."
  def invoke(execution_context, request, opts) do
    with {:ok, context} <- Context.fetch(execution_context),
         {:ok, prompt} <- request_prompt(request, context),
         {:ok, executable, digest} <- official_configuration(opts),
         {:ok, tools} <- approved_tools(context, Keyword.get(opts, :tools, [])),
         :ok <-
           Tool.authorize(context, capability(), %{
             operation: :verify_official_binary,
             executable: executable
           }),
         :ok <- verify_binary(executable, digest),
         {:ok, authentication} <-
           run_process(context, executable, ["auth", "status"], :claude_auth_status, opts),
         :ok <- subscription_authentication(authentication),
         {:ok, arguments} <- arguments(prompt, tools, opts),
         {:ok, result} <- run_process(context, executable, arguments, :claude_delegate, opts) do
      project_result(result, tools)
    end
  end

  defp request_prompt(request, context) when is_map(request) do
    unknown = Map.keys(request) -- [:prompt, "prompt"]
    prompt = Map.get(request, :prompt, Map.get(request, "prompt"))

    cond do
      unknown != [] ->
        {:error, :unsupported_claude_request}

      not is_binary(prompt) or byte_size(prompt) == 0 ->
        {:error, :invalid_claude_prompt}

      byte_size(prompt) > Map.get(context.limits, :claude_prompt_bytes, 65_536) ->
        {:error, :claude_prompt_too_large}

      String.contains?(prompt, <<0>>) ->
        {:error, :invalid_claude_prompt}

      true ->
        {:ok, prompt}
    end
  end

  defp request_prompt(_request, _context), do: {:error, :unsupported_claude_request}

  defp official_configuration(opts) do
    executable = Keyword.get(opts, :executable)
    digest = Keyword.get(opts, :sha256)

    if Keyword.get(opts, :official_binary) == true and is_binary(executable) and
         Path.type(executable) == :absolute and is_binary(digest) and
         Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, digest) do
      {:ok, executable, String.downcase(digest)}
    else
      {:error, :official_claude_code_required}
    end
  end

  defp approved_tools(context, tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case Map.fetch(@tool_capabilities, tool) do
        {:ok, capability} ->
          granted_tool(context, capability, tool, acc)

        :error ->
          {:halt, {:error, :unsupported_claude_tool}}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, tools |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp approved_tools(_context, _tools), do: {:error, :unsupported_claude_tool}

  defp granted_tool(context, capability, tool, acc) do
    if Context.permitted?(context, capability),
      do: {:cont, {:ok, [tool | acc]}},
      else: {:halt, {:error, {:permission_denied, capability}}}
  end

  defp verify_binary(path, digest) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o111) != 0,
         actual = executable_digest(path),
         true <- actual == digest do
      :ok
    else
      _mismatch -> {:error, :claude_binary_changed}
    end
  rescue
    _error -> {:error, :claude_binary_changed}
  end

  defp executable_digest(path) do
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), fn bytes, digest ->
      :crypto.hash_update(digest, bytes)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp arguments(prompt, tools, opts) do
    turns = Keyword.get(opts, :max_turns, 8)
    model = Keyword.get(opts, :model)

    if is_integer(turns) and turns > 0 and turns <= 100 and
         (is_nil(model) or (is_binary(model) and byte_size(model) > 0)) do
      arguments = [
        "--restricted",
        "--safe-mode",
        "--print",
        "--output-format",
        "json",
        "--no-session-persistence",
        "--permission-mode",
        "manual",
        "--permission-prompts",
        "none",
        "--strict-mcp-config",
        "--mcp-config",
        "{\"mcpServers\":{}}",
        "--disallowedTools",
        "mcp__*",
        "--disable-slash-commands",
        "--no-chrome",
        "--tools",
        Enum.join(tools, ","),
        "--allowedTools",
        Enum.join(tools, ","),
        "--max-turns",
        Integer.to_string(turns)
      ]

      arguments = if model, do: arguments ++ ["--model", model], else: arguments
      {:ok, arguments ++ ["--", prompt]}
    else
      {:error, :invalid_claude_configuration}
    end
  end

  defp run_process(context, executable, arguments, operation, opts) do
    timeout =
      min(
        Keyword.get(opts, :timeout, 120_000),
        Map.get(context.limits, :claude_timeout_ms, 120_000)
      )

    maximum =
      min(
        Keyword.get(opts, :max_output_bytes, 262_144),
        Map.get(context.limits, :claude_output_bytes, 262_144)
      )

    environment = Map.new(@removed_environment, &{&1, nil})

    case OhMyJido.Process.run(context, executable, arguments,
           capability: capability(),
           effect: %{sensitive: true, operation: operation, separate_agent: true},
           env: environment,
           cwd: ".",
           timeout: timeout,
           max_output_bytes: maximum
         ) do
      {:ok, result} -> {:ok, result}
      {:error, {:permission_denied, _capability}} = error -> error
      {:error, reason} when reason in [:approval_required, :approval_denied] -> {:error, reason}
      {:error, _reason} -> {:error, :claude_process_failed}
    end
  end

  defp subscription_authentication(result) do
    with :ok <- completed_process(result),
         {:ok, %{"loggedIn" => true, "authMethod" => "claude.ai"}} <- Jason.decode(result.stdout) do
      :ok
    else
      _failure -> {:error, :claude_subscription_login_required}
    end
  end

  defp project_result(%{effect: :uncertain} = result, _tools) do
    {:error,
     %{
       reason: :claude_process_incomplete,
       effect: :uncertain,
       status: result.status,
       cleanup: result.cleanup
     }}
  end

  defp project_result(%{status: :exited, cleanup: :confirmed, truncated: false} = result, tools) do
    case Jason.decode(result.stdout) do
      {:ok, decoded} -> project_terminal(decoded, result.exit_status, tools)
      _invalid -> {:error, :claude_delegation_failed}
    end
  end

  defp project_result(result, _tools), do: completed_process(result)

  defp project_terminal(
         %{"type" => "result", "subtype" => "success", "is_error" => false, "result" => answer} =
           decoded,
         0,
         tools
       )
       when is_binary(answer) do
    {:ok,
     %{
       answer: answer,
       integration: :official_claude_code,
       native_jido_loop: false,
       auth_method: :claude_ai,
       tools: tools,
       usage: safe_usage(decoded["usage"])
     }}
  end

  defp project_terminal(
         %{"type" => "result", "is_error" => true, "api_error_status" => status},
         _exit_status,
         _tools
       )
       when is_integer(status) and status in 400..599 do
    code =
      Map.get(
        %{401 => :reauth_required, 403 => :access_denied, 429 => :rate_limited},
        status,
        :provider_error
      )

    {:error, OhMyJido.Auth.Error.new(code, %{provider: :anthropic, status: status})}
  end

  defp project_terminal(_decoded, 0, _tools), do: {:error, :claude_delegation_failed}
  defp project_terminal(_decoded, _exit_status, _tools), do: {:error, :claude_process_failed}

  defp completed_process(%{
         exit_status: 0,
         status: :exited,
         cleanup: :confirmed,
         truncated: false
       }),
       do: :ok

  defp completed_process(%{exit_status: 0}), do: {:error, :claude_process_incomplete}
  defp completed_process(_result), do: {:error, :claude_process_failed}

  defp safe_usage(usage) when is_map(usage) do
    Enum.reduce(
      [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens],
      %{},
      fn key, acc ->
        case Map.get(usage, Atom.to_string(key)) do
          count when is_integer(count) and count >= 0 -> Map.put(acc, key, count)
          _unknown -> acc
        end
      end
    )
  end

  defp safe_usage(_usage), do: %{}
end
