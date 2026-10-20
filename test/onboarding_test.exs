defmodule OhMyJido.OnboardingTest do
  use ExUnit.Case, async: false

  alias OhMyJido.Files

  defmodule ApprovedHost do
    def authorize(context, _capability, _effect, opts) do
      if context.workspace == opts[:workspace], do: :ok, else: {:error, :wrong_workspace}
    end

    def credentials(_context, _account, _opts), do: {:error, :credentials_required}
    def invoke(_context, _capability, _request, _opts), do: {:error, :unconfigured}
    def question(_context, _question, _opts), do: {:error, :unconfigured}
  end

  defmodule Credentials do
    def resolve(_context, account, opts) do
      send(opts[:owner], {:explicit_credentials_resolved, account})
      {:error, :credentials_required}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-onboarding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "original\r\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{workspace: root}
  end

  test "the public supervisor child starts no session, and a read bundle needs an explicit grant",
       %{workspace: root} do
    start_supervised!({OhMyJido, name: __MODULE__.ReadOnly, bundles: :read_only})
    assert OhMyJido.list_sessions(__MODULE__.ReadOnly) == []

    {:ok, denied} = OhMyJido.start_session(__MODULE__.ReadOnly, workspace: root)
    assert {:error, _reason} = OhMyJido.execute_tool(denied, "read", %{path: "input.txt"})
    assert File.read!(Path.join(root, "input.txt")) == "original\r\n"
    assert :ok = OhMyJido.stop_session(denied)

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.ReadOnly, workspace: root, permissions: [:read, :edit])

    assert {:ok, %{content: "original\r\n"}} =
             OhMyJido.execute_tool(session, "read", %{path: "input.txt"})

    assert {:error, {:unknown_tool, "edit"}} =
             OhMyJido.execute_tool(session, "edit", %{path: "input.txt"})

    assert File.read!(Path.join(root, "input.txt")) == "original\r\n"
    assert :ok = OhMyJido.stop_session(session)
  end

  test "a session bundle replaces runtime availability without broadening grants", %{
    workspace: root
  } do
    start_supervised!(
      {OhMyJido,
       name: __MODULE__.Selected, bundles: :read_only, host: {ApprovedHost, workspace: root}}
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Selected,
        workspace: root,
        bundles: :editing,
        permissions: [:edit]
      )

    assert {:error, {:unknown_tool, "read"}} =
             OhMyJido.execute_tool(session, "read", %{path: "input.txt"})

    assert {:ok, _receipt} =
             OhMyJido.execute_tool(session, "write", %{
               path: "input.txt",
               content: "changed\r\n",
               snapshot: Files.snapshot("original\r\n")
             })

    assert File.read!(Path.join(root, "input.txt")) == "changed\r\n"
    assert :ok = OhMyJido.stop_session(session)
  end

  test "invalid bundle and ambiguous tool config fail before creating a native agent", %{
    workspace: root
  } do
    start_supervised!({OhMyJido, name: __MODULE__.Invalid})

    assert {:error, {:invalid_session_option, :bundles, _reason}} =
             OhMyJido.start_session(__MODULE__.Invalid, workspace: root, bundles: :not_a_bundle)

    assert {:error, {:conflicting_options, [:bundles, :tools]}} =
             OhMyJido.start_session(__MODULE__.Invalid,
               workspace: root,
               bundles: :read_only,
               tools: []
             )

    assert {:error, {:invalid_session_option, :tools, :expected_action_modules}} =
             OhMyJido.start_session(__MODULE__.Invalid, workspace: root, tools: ["read"])

    assert OhMyJido.list_sessions(__MODULE__.Invalid) == []
    assert File.read!(Path.join(root, "input.txt")) == "original\r\n"
  end

  test "runtime and session selections keep explicit tools precedence", %{workspace: root} do
    start_supervised!({OhMyJido, name: __MODULE__.Explicit, bundles: :editing})

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Explicit,
        workspace: root,
        tools: [OhMyJido.Tools.Read],
        permissions: [:read, :edit]
      )

    assert {:ok, %{content: "original\r\n"}} =
             OhMyJido.execute_tool(session, "read", %{path: "input.txt"})

    assert {:error, {:unknown_tool, "write"}} =
             OhMyJido.execute_tool(session, "write", %{path: "input.txt", content: "no"})

    assert File.read!(Path.join(root, "input.txt")) == "original\r\n"
    assert :ok = OhMyJido.stop_session(session)
  end

  test "resolved bundle availability survives restore when runtime defaults change", %{
    workspace: root
  } do
    name = __MODULE__.Restored
    storage = {Jido.Persistence.File, path: Path.join(root, ".sessions")}
    start_supervised!({OhMyJido, name: name, bundles: :read_only, storage: storage})
    {:ok, original} = OhMyJido.start_session(name, workspace: root, permissions: [:read, :edit])
    assert :ok = OhMyJido.checkpoint(original)
    assert :ok = OhMyJido.stop_session(original)
    stop_supervised!(name)

    start_supervised!({OhMyJido, name: name, bundles: :editing, storage: storage})
    assert {:ok, restored} = OhMyJido.resume_session(name, original.id)

    assert {:ok, %{content: "original\r\n"}} =
             OhMyJido.execute_tool(restored, "read", %{path: "input.txt"})

    assert {:error, {:unknown_tool, "write"}} =
             OhMyJido.execute_tool(restored, "write", %{path: "input.txt", content: "no"})

    assert File.read!(Path.join(root, "input.txt")) == "original\r\n"
    assert :ok = OhMyJido.stop_session(restored)
  end

  test "explicit runtime credential resolver reaches Host.Local without provider traffic", %{
    workspace: root
  } do
    start_supervised!(
      {OhMyJido, name: __MODULE__.CredentialRuntime, credentials: {Credentials, owner: self()}}
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.CredentialRuntime,
        workspace: root,
        account: :approved_account
      )

    assert {:ok, run} = OhMyJido.prompt(session, "Report readiness without tools")
    assert_receive {:explicit_credentials_resolved, :approved_account}, 10_000
    assert {:error, _failure} = OhMyJido.await(session, run, timeout: 10_000)
    assert File.read!(Path.join(root, "input.txt")) == "original\r\n"
    assert :ok = OhMyJido.stop_session(session)
  end

  test "credential convenience never silently replaces a custom host", %{workspace: root} do
    assert {:error, _configuration_error} =
             start_supervised(
               {OhMyJido,
                name: __MODULE__.Custom,
                host: {ApprovedHost, workspace: root},
                credentials: {Credentials, owner: self()}}
             )

    assert Process.whereis(__MODULE__.Custom) == nil
    refute_receive {:explicit_credentials_resolved, _account}
  end
end
