defmodule OhMyJido.Tools.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Tools.ClaudeCode}

  defmodule Host do
    def authorize(_context, capability, effect, opts) do
      send(opts[:test_pid], {:authorized, capability, effect})
      :ok
    end

    def credentials(_context, _account, _opts), do: {:error, :not_used}
    def invoke(_context, _capability, _request, _opts), do: {:error, :not_used}
    def question(_context, _question, _opts), do: {:error, :not_used}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "omj-claude-fixture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    binary = Path.join(root, "official-cli-fixture")

    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
      printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
      exit 0
    fi
    if [ -n "${ANTHROPIC_API_KEY+x}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN+x}" ]; then
      exit 23
    fi
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Delegated review fixture","usage":{"input_tokens":11,"output_tokens":7},"access_token":"never return this field"}'
    """)

    File.chmod!(binary, 0o700)
    sha256 = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16(case: :lower)

    opts = [
      executable: binary,
      sha256: sha256,
      official_binary: true,
      tools: ["Read", "Glob", "Grep"]
    ]

    context = %Context{
      session_id: "claude-fixture",
      workspace: root,
      permissions: MapSet.new([:claude_code, :read]),
      host: {Host, test_pid: self()},
      adapters: %{claude_code: {ClaudeCode, opts}}
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{context: context, opts: opts, binary: binary}
  end

  test "projects completed official results without leaking unrecognized credential fields",
       %{context: context} do
    assert {:ok, result} = ClaudeCode.run(%{prompt: "Review the supplied plan."}, context)
    refute inspect(result) =~ "never return this field"
    assert_receive {:authorized, :claude_code, %{operation: :verify_official_binary}}
    assert_receive {:authorized, :claude_code, %{operation: :claude_auth_status}}

    assert_receive {:authorized, :claude_code, %{operation: :claude_delegate}}
  end

  test "requires explicit host approval of an unchanged official executable", %{
    context: context,
    opts: opts,
    binary: binary
  } do
    unapproved = Keyword.put(opts, :official_binary, false)

    assert {:error, :official_claude_code_required} =
             ClaudeCode.invoke(context, %{prompt: "Hello"}, unapproved)

    File.write!(binary, "#!/bin/sh\nexit 0\n")
    assert {:error, :claude_binary_changed} = ClaudeCode.invoke(context, %{prompt: "Hello"}, opts)
  end

  test "does not widen tool grants or accept executable/extra argument overrides", %{
    context: context,
    opts: opts
  } do
    assert {:error, {:permission_denied, :edit}} =
             ClaudeCode.invoke(context, %{prompt: "Edit"}, Keyword.put(opts, :tools, ["Write"]))

    assert {:error, :unsupported_claude_request} =
             ClaudeCode.invoke(context, %{prompt: "Hi", executable: "/bin/sh"}, opts)

    denied = %{context | permissions: MapSet.delete(context.permissions, :claude_code)}

    assert {:error, {:permission_denied, :claude_code}} =
             ClaudeCode.invoke(denied, %{prompt: "Hi"}, opts)
  end

  test "truncated delegated output cannot become a successful answer", %{
    context: context,
    opts: opts
  } do
    assert {:error, :claude_process_incomplete} =
             ClaudeCode.invoke(
               context,
               %{prompt: "Review"},
               Keyword.put(opts, :max_output_bytes, 64)
             )
  end

  test "a structured CLI error is not partial success and does not expose its raw body", %{
    context: context,
    opts: opts,
    binary: binary
  } do
    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
      printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
    else
      printf '%s\\n' '{"type":"result","is_error":true,"subtype":"error_during_execution","result":"raw-token-in-error"}'
    fi
    """)

    digest = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16(case: :lower)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :claude_delegation_failed} =
                 ClaudeCode.invoke(
                   context,
                   %{prompt: "Review"},
                   Keyword.put(opts, :sha256, digest)
                 )
      end)

    assert_receive {:authorized, :claude_code, %{operation: :claude_delegate, sensitive: true}}
    refute log =~ "raw-token-in-error"
  end

  test "native nonzero subscription denial keeps its machine status without exposing the body", %{
    context: context,
    opts: opts,
    binary: binary
  } do
    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
      printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
    else
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"private-provider-body"}'
      exit 1
    fi
    """)

    digest = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16(case: :lower)

    assert {:error,
            %OhMyJido.Auth.Error{code: :rate_limited, status: 429, provider: :anthropic} = error} =
             ClaudeCode.invoke(context, %{prompt: "Review"}, Keyword.put(opts, :sha256, digest))

    refute inspect(error) =~ "private-provider-body"
  end

  test "a timed-out delegate preserves its completed write and reports uncertain effects", %{
    context: context,
    opts: opts,
    binary: binary
  } do
    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
      printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
    else
      printf '%s' 'completed before timeout' > completed.txt
      exec sleep 5
    fi
    """)

    digest = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16(case: :lower)
    options = opts |> Keyword.put(:sha256, digest) |> Keyword.put(:timeout, 250)

    assert {:error, %{effect: :uncertain, status: :timed_out, cleanup: :confirmed}} =
             ClaudeCode.invoke(context, %{prompt: "Review"}, options)

    assert File.read!(Path.join(context.workspace, "completed.txt")) == "completed before timeout"
  end

  test "rejects metered and imported-token auth methods instead of silent subscription fallback",
       %{context: context, opts: opts, binary: binary} do
    File.write!(
      binary,
      "#!/bin/sh\nprintf '%s\\n' '{\"loggedIn\":true,\"authMethod\":\"api_key\"}'\n"
    )

    digest = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16(case: :lower)

    assert {:error, :claude_subscription_login_required} =
             ClaudeCode.invoke(context, %{prompt: "Hi"}, Keyword.put(opts, :sha256, digest))
  end
end
