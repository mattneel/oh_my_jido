defmodule OhMyJido.ContextConstructorTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Tool, Tools, Workspace}
  alias OhMyJido.Tools.Read

  defmodule CustomAction do
    use Jido.Action,
      name: "context_custom_digest",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, execution_context) do
      with {:ok, context} <- Context.fetch(execution_context),
           {:ok, content} <- File.read(Path.join(context.workspace, "note.txt")) do
        {:ok, %{digest: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}}
      end
    end
  end

  defmodule RecordingHost do
    @behaviour OhMyJido.Host

    @impl true
    def authorize(_context, capability, _effect, opts) do
      send(opts[:owner], {:host_called, :authorize, capability})
      :ok
    end

    @impl true
    def credentials(_context, _account, opts) do
      send(opts[:owner], {:host_called, :credentials})
      {:error, :credentials_required}
    end

    @impl true
    def invoke(_context, capability, _request, opts) do
      send(opts[:owner], {:host_called, :invoke, capability})
      {:error, {:capability_unavailable, capability}}
    end

    @impl true
    def question(_context, _question, opts) do
      send(opts[:owner], {:host_called, :question})
      :pending
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "omj-context-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "note.txt"), "workspace note")
    File.write!(Path.join(outside, "secret.txt"), "outside note")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, root: root, outside: outside}
  end

  test "safe defaults advertise read tools but grant no authority", %{root: root} do
    assert {:ok, context} = Context.new(workspace: root)
    assert is_binary(context.session_id) and context.session_id != ""
    assert context.permissions == MapSet.new()
    assert context.tools == Tools.select!(:read_only)
    assert context.coordinator == nil
    assert context.runtime == nil
    assert Context.fetch(context) == {:ok, context}
    assert Context.fetch(%{oh_my_jido: context}) == {:ok, context}

    assert_reason(Tool.execute(context, "read", %{path: "note.txt"}), {:permission_denied, :read})
  end

  test "explicit read grants operate only inside a canonical existing workspace", fixture do
    link = Path.join(fixture.base, "workspace-link")
    File.ln_s!(fixture.root, link)
    File.ln_s!(Path.join(fixture.outside, "secret.txt"), Path.join(fixture.root, "escape"))

    context = Context.new!(workspace: link, session_id: "host-read", permissions: [:read, :read])
    assert {:ok, canonical} = Workspace.new(fixture.root)
    assert context.workspace == canonical
    assert context.session_id == "host-read"
    assert context.permissions == MapSet.new([:read])

    assert {:ok, %{content: "workspace note", path: "note.txt"}} =
             Tool.execute(context, "read", %{path: "note.txt"})

    for path <- ["../outside/secret.txt", Path.join(fixture.outside, "secret.txt"), "escape"] do
      assert_reason(Tool.execute(context, "read", %{path: path}), :outside_workspace)
    end
  end

  test "explicit read limits remain effective through the actual action", %{root: root} do
    context =
      Context.new!(workspace: root, permissions: [:read], limits: %{max_read_bytes: 4})

    assert {:ok, %{content: "work", truncated: true}} =
             Tool.execute(context, "read", %{path: "note.txt", max_bytes: 100})
  end

  test "effectful bundles add no grants and denied writes leave files unchanged", %{root: root} do
    context =
      Context.new!(workspace: root, bundles: [:read_only, :editing, :process, :live_inspection])

    assert OhMyJido.Tools.Edit in context.tools
    assert OhMyJido.Tools.Shell in context.tools
    assert OhMyJido.Tools.Observer in context.tools
    assert context.permissions == MapSet.new()

    assert_reason(
      Tool.execute(context, "write", %{path: "new.txt", snapshot: "missing", content: "denied"}),
      {:permission_denied, :edit}
    )

    assert_reason(
      Tool.execute(context, "edit", %{
        path: "note.txt",
        snapshot: sha256("workspace note"),
        edits: [%{old: "workspace note", new: "denied"}]
      }),
      {:permission_denied, :edit}
    )

    assert {:error, _denial} = Tool.execute(context, "shell", %{executable: "true"})
    assert {:error, _denial} = Tool.execute(context, "observer", %{operation: "overview"})

    assert File.read!(Path.join(root, "note.txt")) == "workspace note"
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "explicit custom tools replace defaults, deduplicate stably and still need authority", %{
    root: root
  } do
    context = Context.new!(workspace: root, tools: [CustomAction, Read, CustomAction])
    assert context.tools == [CustomAction, Read]

    assert_reason(
      Tool.execute(context, "context_custom_digest", %{}),
      {:permission_denied, :custom}
    )

    granted =
      Context.new!(workspace: root, tools: [CustomAction], permissions: MapSet.new([:custom]))

    assert {:ok, %{digest: digest}} = Tool.execute(granted, "context_custom_digest", %{})
    assert digest == sha256(File.read!(Path.join(root, "note.txt")))

    assert {:error, {:unknown_tool, "read"}} = Tool.find(granted, "read")
  end

  test "workspace errors identify missing, malformed and non-directory roots", fixture do
    assert {:error, {:invalid_context, :workspace, :required}} = Context.new([])

    for root <- [nil, 42, "", <<255>>, "invalid\0path"] do
      assert {:error, {:invalid_context, :workspace, :invalid_path}} =
               Context.new(workspace: root)
    end

    assert {:error, {:invalid_context, :workspace, :enoent}} =
             Context.new(workspace: Path.join(fixture.base, "absent"))

    assert {:error, {:invalid_context, :workspace, :enotdir}} =
             Context.new(workspace: Path.join(fixture.root, "note.txt"))

    assert_raise ArgumentError, ~r/invalid context.*workspace.*enoent/, fn ->
      Context.new!(workspace: Path.join(fixture.base, "absent"))
    end
  end

  test "bundle errors remain structured and conflicting availability is rejected", %{root: root} do
    assert {:error, {:invalid_context, :bundles, {:unknown_bundle, :no_such_bundle}}} =
             Context.new(workspace: root, bundles: [:read_only, :no_such_bundle])

    assert {:error, {:invalid_context, :bundles, {:invalid_bundle, "editing"}}} =
             Context.new(workspace: root, bundles: ["editing"])

    assert {:error, {:invalid_context, :tools, {:conflicts_with, :bundles}}} =
             Context.new(workspace: root, tools: [Read], bundles: :read_only)
  end

  test "malformed trusted configuration fails with the responsible field", %{root: root} do
    assert {:error, {:invalid_context, :options, :expected_keyword_list}} = Context.new(%{})

    assert {:error, {:invalid_context, :options, :expected_keyword_list}} =
             Context.new(["workspace"])

    assert {:error, {:invalid_context, :unknown_setting, :unknown_option}} =
             Context.new(workspace: root, unknown_setting: true)

    assert {:error, {:invalid_context, :permissions, :duplicate_option}} =
             Context.new(workspace: root, permissions: [], permissions: [:read])

    for {field, value} <- [
          session_id: "",
          run_id: 3,
          runtime: "runtime",
          coordinator: :not_a_pid,
          role: nil,
          permissions: :read,
          permissions: ["read"],
          permissions: [nil],
          permissions: MapSet.new([false]),
          tools: Read,
          tools: ["Elixir.OhMyJido.Tools.Read"],
          tools: [String],
          tools: [Read | :invalid],
          host: nil,
          host: String,
          host: {RecordingHost, %{}},
          adapters: [],
          adapters: %{"browser" => {RecordingHost, []}},
          adapters: %{browser: RecordingHost},
          adapters: %{browser: {String, []}},
          limits: [],
          limits: %{max_read_bytes: -1},
          limits: %{max_read_bytes: "4"},
          metadata: []
        ] do
      assert {:error, {:invalid_context, ^field, _reason}} =
               Context.new([{:workspace, root}, {field, value}])
    end
  end

  test "permission strings never create atoms", %{root: root} do
    permission = "untrusted-permission-#{System.unique_integer([:positive])}"

    assert {:error, {:invalid_context, :permissions, :expected_atom_list_or_map_set}} =
             Context.new(workspace: root, permissions: [permission])

    assert_raise ArgumentError, fn -> String.to_existing_atom(permission) end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp assert_reason({:error, %Jido.Action.Error.ExecutionFailureError{details: details}}, reason) do
    assert details.reason == reason
  end

  defp assert_reason({:error, actual}, reason), do: assert(actual == reason)
end
