defmodule OhMyJido.FilesTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Tool, Workspace}
  alias OhMyJido.Tools.{Edit, List, Read, Search, Write}

  defmodule ArtifactRead do
    use Jido.Action,
      name: "artifact_file_boundary",
      schema: Zoi.object(%{path: Zoi.string()}, coerce: true)

    def capability, do: :artifact

    @impl true
    def run(params, context) do
      with {:ok, file} <- OhMyJido.Files.read_artifact_bytes(context, params.path) do
        {:ok, %{path: file.path, base64: Base.encode64(file.content), snapshot: file.snapshot}}
      end
    end
  end

  defmodule BoundaryHost do
    @behaviour OhMyJido.Host

    def authorize(_context, _capability, _effect, opts) do
      send(opts[:owner], {:at_file_boundary, self()})

      receive do
        :allow -> :ok
      after
        5_000 -> {:error, :approval_timeout}
      end
    end

    def credentials(_context, _account, _opts), do: {:error, :credentials_required}

    def invoke(_context, capability, _request, _opts),
      do: {:error, {:capability_unavailable, capability}}

    def question(_context, _question, _opts), do: :pending
  end

  setup do
    base = Path.join(System.tmp_dir!(), "omj-files-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    outside = Path.join(base, "root-other")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "outside secret")
    on_exit(fn -> File.rm_rf!(base) end)

    context = %Context{
      session_id: "files-test",
      workspace: root,
      permissions: MapSet.new([:read, :edit]),
      tools: [Read, Write, Edit, Search, List]
    }

    %{base: base, root: root, outside: outside, context: context}
  end

  test "Jido Actions return exact UTF-8 and CRLF text with whole-file SHA256 snapshots",
       fixture do
    content = "α🙂\r\nsecond\r\n終わり"
    File.write!(Path.join(fixture.root, "unicode.txt"), content)

    assert {:ok, result} = Tool.execute(fixture.context, "read", %{path: "unicode.txt"})
    assert result.content == content
    assert result.snapshot == sha256(content)
    assert result.encoding == "utf8"
    assert result.newline == "crlf"
    assert result.line_count == 3
    assert result.bytes == byte_size(content)
    refute result.binary
    refute result.truncated
    assert result.path == "unicode.txt"

    assert {:ok, range} =
             Tool.execute(fixture.context, "read", %{
               path: "unicode.txt",
               start_line: 2,
               end_line: 2
             })

    assert range.content == "second\r\n"
    assert range.snapshot == result.snapshot
    assert {range.start_line, range.end_line} == {2, 2}
    assert range.line_count == 3
  end

  test "empty and unterminated files have precise line counts", fixture do
    for {path, content, count} <- [
          {"empty", "", 0},
          {"last", "one\ntwo", 2},
          {"newline", "one\n", 1}
        ] do
      File.write!(Path.join(fixture.root, path), content)
      assert {:ok, result} = Tool.execute(fixture.context, "read", %{path: path})
      assert result.content == content
      assert result.line_count == count
      assert result.snapshot == sha256(content)
    end
  end

  test "ranges are inclusive and malformed or out-of-bounds ranges fail clearly", fixture do
    File.write!(Path.join(fixture.root, "lines"), "first\nsecond\nthird")

    assert {:ok, result} =
             Tool.execute(fixture.context, "read", %{path: "lines", start_line: 2, end_line: 50})

    assert result.content == "second\nthird"
    assert result.end_line == 3

    assert_reason(
      Tool.execute(fixture.context, "read", %{path: "lines", start_line: 3, end_line: 2}),
      :invalid_range
    )

    assert_reason(
      Tool.execute(fixture.context, "read", %{path: "lines", start_line: 4}),
      :range_out_of_bounds
    )

    assert {:error, _} = Tool.execute(fixture.context, "read", %{path: "lines", start_line: 0})
  end

  test "binary and invalid UTF-8 content is detected without lossy decoding", fixture do
    for {path, content} <- [{"nul", <<65, 0, 66>>}, {"invalid", <<255, 254, 65>>}] do
      File.write!(Path.join(fixture.root, path), content)
      assert {:ok, result} = Tool.execute(fixture.context, "read", %{path: path})
      assert result.binary
      assert result.encoding == "binary"
      assert result.content == nil
      assert Base.decode64!(result.base64) == content
      assert result.snapshot == sha256(content)

      assert_reason(
        Tool.execute(fixture.context, "edit", %{
          path: path,
          snapshot: result.snapshot,
          edits: [%{old: "A", new: "B"}]
        }),
        :binary_file
      )
    end
  end

  test "output truncation never splits UTF-8 and cannot raise host limits", fixture do
    File.write!(Path.join(fixture.root, "large"), "a🙂b\nnext")
    context = %{fixture.context | limits: %{max_read_bytes: 4, max_file_bytes: 32}}
    assert {:ok, result} = Tool.execute(context, "read", %{path: "large", max_bytes: 100})
    assert result.content == "a"
    assert result.truncated
    assert result.truncation.output
    assert String.valid?(result.content)
    assert result.snapshot == sha256("a🙂b\nnext")

    File.write!(Path.join(fixture.root, "too-large"), String.duplicate("x", 33))
    assert_reason(Tool.execute(context, "read", %{path: "too-large"}), :file_too_large)

    assert_reason(
      Tool.execute(context, "write", %{
        path: "created",
        snapshot: "missing",
        content: String.duplicate("x", 33)
      }),
      :file_too_large
    )

    refute File.exists?(Path.join(fixture.root, "created"))
  end

  test "create is atomic and never blindly overwrites existing content", fixture do
    assert {:ok, result} =
             Tool.execute(fixture.context, "write", %{
               path: "created",
               snapshot: "missing",
               content: "new\n"
             })

    assert result.created
    assert result.bytes_written == 4
    assert result.snapshot == sha256("new\n")
    assert result.path == "created"

    assert_reason(
      Tool.execute(fixture.context, "write", %{
        path: "created",
        snapshot: "missing",
        content: "overwrite"
      }),
      :stale_snapshot
    )

    assert File.read!(Path.join(fixture.root, "created")) == "new\n"

    assert {:error, _} =
             Tool.execute(fixture.context, "write", %{path: "created", content: "blind"})
  end

  test "writes replace the inode atomically and preserve permission mode", fixture do
    path = Path.join(fixture.root, "executable")
    File.write!(path, "original")
    File.chmod!(path, 0o750)
    before_stat = File.stat!(path)
    {:ok, old_descriptor} = File.open(path, [:read, :binary])
    on_exit(fn -> File.close(old_descriptor) end)
    {:ok, read} = Tool.execute(fixture.context, "read", %{path: "executable"})

    assert {:ok, write} =
             Tool.execute(fixture.context, "write", %{
               path: "executable",
               snapshot: read.snapshot,
               content: "replacement"
             })

    refute write.created
    assert write.previous_snapshot == read.snapshot
    assert IO.binread(old_descriptor, :eof) == "original"
    assert File.read!(path) == "replacement"
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o750
    refute File.stat!(path).inode == before_stat.inode
    assert File.ls!(fixture.root) == ["executable"]
  end

  test "exact edits preserve unrelated Unicode and CRLF bytes", fixture do
    original = "keep α\r\nold target\r\nkeep 🙂\r\nend"
    File.write!(Path.join(fixture.root, "edit.txt"), original)
    {:ok, read} = Tool.execute(fixture.context, "read", %{path: "edit.txt"})

    assert {:ok, result} =
             Tool.execute(fixture.context, "edit", %{
               path: "edit.txt",
               snapshot: read.snapshot,
               edits: [%{old: "old target", new: "new target"}]
             })

    expected = "keep α\r\nnew target\r\nkeep 🙂\r\nend"
    assert File.read!(Path.join(fixture.root, "edit.txt")) == expected
    assert result.snapshot == sha256(expected)
    assert result.replacements == 1

    assert_reason(
      Tool.execute(fixture.context, "edit", %{
        path: "edit.txt",
        snapshot: read.snapshot,
        edits: [%{old: "keep", new: "discard"}]
      }),
      :stale_snapshot
    )
  end

  test "edits resolve against the original snapshot and reject ambiguity and overlap", fixture do
    File.write!(Path.join(fixture.root, "targets"), "abc abc end")
    {:ok, read} = Tool.execute(fixture.context, "read", %{path: "targets"})

    assert_reason(
      Tool.execute(fixture.context, "edit", %{
        path: "targets",
        snapshot: read.snapshot,
        edits: [%{old: "abc", new: "x"}]
      }),
      :ambiguous_match
    )

    assert_reason(
      Tool.execute(fixture.context, "edit", %{
        path: "targets",
        snapshot: read.snapshot,
        edits: [%{old: "missing", new: "x"}]
      }),
      :target_not_found
    )

    assert_reason(
      Tool.execute(fixture.context, "edit", %{
        path: "targets",
        snapshot: read.snapshot,
        edits: [%{old: "abc", new: "x", occurrence: 1}, %{old: "bc", new: "y", occurrence: 1}]
      }),
      :overlapping_edits
    )

    assert File.read!(Path.join(fixture.root, "targets")) == "abc abc end"

    assert {:ok, result} =
             Tool.execute(fixture.context, "edit", %{
               path: "targets",
               snapshot: read.snapshot,
               edits: [%{old: "abc", new: "end", occurrence: 2}, %{old: "end", new: "done"}]
             })

    assert result.replacements == 2
    assert File.read!(Path.join(fixture.root, "targets")) == "abc end done"
  end

  test "racing edits of the same snapshot have exactly one winner", fixture do
    File.write!(Path.join(fixture.root, "race"), "start")
    {:ok, read} = Tool.execute(fixture.context, "read", %{path: "race"})
    caller = self()

    tasks =
      for replacement <- ["one", "two"] do
        Task.async(fn ->
          send(caller, {:ready, self()})
          receive do: (:go -> :ok)

          Tool.execute(fixture.context, "edit", %{
            path: "race",
            snapshot: read.snapshot,
            edits: [%{old: "start", new: replacement}]
          })
        end)
      end

    assert_receive {:ready, first}, 5_000
    assert_receive {:ready, second}, 5_000
    send(first, :go)
    send(second, :go)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    [conflict] = Enum.filter(results, &match?({:error, _}, &1))
    assert_reason(conflict, :stale_snapshot)
    assert File.read!(Path.join(fixture.root, "race")) in ["one", "two"]
  end

  test "racing creates also have exactly one winner", fixture do
    results =
      ["one", "two"]
      |> Task.async_stream(
        fn content ->
          Tool.execute(fixture.context, "write", %{
            path: "new-race",
            snapshot: "missing",
            content: content
          })
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    [conflict] = Enum.filter(results, &match?({:error, _}, &1))
    assert_reason(conflict, :stale_snapshot)
    assert File.read!(Path.join(fixture.root, "new-race")) in ["one", "two"]
  end

  test "deleted files produce snapshot conflicts rather than an implicit create", fixture do
    File.write!(Path.join(fixture.root, "gone"), "original")
    {:ok, read} = Tool.execute(fixture.context, "read", %{path: "gone"})
    File.rm!(Path.join(fixture.root, "gone"))

    assert_reason(
      Tool.execute(fixture.context, "write", %{
        path: "gone",
        snapshot: read.snapshot,
        content: "resurrect"
      }),
      :stale_snapshot
    )

    refute File.exists?(Path.join(fixture.root, "gone"))
  end

  test "explicit capability denials never perform reads or writes", fixture do
    denied = %{fixture.context | permissions: MapSet.new()}
    File.write!(Path.join(fixture.root, "private"), "original")
    assert_reason(Tool.execute(denied, "read", %{path: "private"}), {:permission_denied, :read})

    assert_reason(
      Tool.execute(denied, "write", %{path: "new", snapshot: "missing", content: "denied"}),
      {:permission_denied, :edit}
    )

    assert_reason(
      Tool.execute(denied, "edit", %{
        path: "private",
        snapshot: sha256("original"),
        edits: [%{old: "original", new: "denied"}]
      }),
      {:permission_denied, :edit}
    )

    assert File.read!(Path.join(fixture.root, "private")) == "original"
    refute File.exists?(Path.join(fixture.root, "new"))
  end

  test "file modes deny protected reads and replacements without leaving temporary files",
       fixture do
    path = Path.join(fixture.root, "protected")
    File.write!(path, "protected")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)
    assert_reason(Tool.execute(fixture.context, "read", %{path: "protected"}), :eacces)
    File.chmod!(path, 0o400)

    assert_reason(
      Tool.execute(fixture.context, "write", %{
        path: "protected",
        snapshot: sha256("protected"),
        content: "denied"
      }),
      :eacces
    )

    assert_reason(
      Tool.execute(fixture.context, "edit", %{
        path: "protected",
        snapshot: sha256("protected"),
        edits: [%{old: "protected", new: "denied"}]
      }),
      :eacces
    )

    assert File.read!(path) == "protected"
    assert File.ls!(fixture.root) == ["protected"]
  end

  test "a denied parent directory cannot be bypassed by atomic creation", fixture do
    parent = Path.join(fixture.root, "locked")
    File.mkdir!(parent)
    File.chmod!(parent, 0o500)
    on_exit(fn -> File.chmod(parent, 0o700) end)

    assert_reason(
      Tool.execute(fixture.context, "write", %{
        path: "locked/file",
        snapshot: "missing",
        content: "denied"
      }),
      :eacces
    )

    refute File.exists?(Path.join(parent, "file"))
  end

  test "all filesystem Actions reject traversal, sibling and absolute escape without content leakage",
       fixture do
    before_cwd = File.cwd!()
    before_env = :crypto.hash(:sha256, :erlang.term_to_binary(System.get_env()))

    for path <- [
          "../root-other/secret.txt",
          fixture.outside <> "/secret.txt",
          fixture.root <> "-other/secret.txt"
        ] do
      for {tool, params} <- [
            {"read", %{path: path}},
            {"write", %{path: path, snapshot: "missing", content: "denied"}},
            {"edit",
             %{
               path: path,
               snapshot: sha256("outside secret"),
               edits: [%{old: "outside", new: "denied"}]
             }},
            {"list", %{path: path}},
            {"search", %{path: path, pattern: "secret"}}
          ] do
        result = Tool.execute(fixture.context, tool, params)
        assert_reason(result, :outside_workspace)
        refute inspect(result) =~ "outside secret"
      end
    end

    assert File.read!(Path.join(fixture.outside, "secret.txt")) == "outside secret"
    assert File.cwd!() == before_cwd
    assert :crypto.hash(:sha256, :erlang.term_to_binary(System.get_env())) == before_env
  end

  test "file and directory symlinks cannot escape the root", fixture do
    File.ln_s!(fixture.outside, Path.join(fixture.root, "escape"))
    File.ln_s!(Path.join(fixture.outside, "secret.txt"), Path.join(fixture.root, "secret-link"))

    for path <- ["escape/secret.txt", "secret-link", "escape/new"] do
      assert_reason(Tool.execute(fixture.context, "read", %{path: path}), :outside_workspace)

      assert_reason(
        Tool.execute(fixture.context, "write", %{
          path: path,
          snapshot: "missing",
          content: "denied"
        }),
        :outside_workspace
      )
    end

    assert File.read!(Path.join(fixture.outside, "secret.txt")) == "outside secret"
    refute File.exists?(Path.join(fixture.outside, "new"))
  end

  test "an in-root symlink uses the canonical target and does not destroy the link", fixture do
    File.write!(Path.join(fixture.root, "target"), "original")
    File.ln_s!("target", Path.join(fixture.root, "alias"))
    {:ok, read} = Tool.execute(fixture.context, "read", %{path: "alias"})
    assert read.path == "target"

    assert {:ok, _} =
             Tool.execute(fixture.context, "write", %{
               path: "alias",
               snapshot: read.snapshot,
               content: "new"
             })

    assert {:ok, "target"} = File.read_link(Path.join(fixture.root, "alias"))
    assert File.read!(Path.join(fixture.root, "target")) == "new"
  end

  test "authority is rechecked after a host approval replaces a parent with an escape", fixture do
    parent = Path.join(fixture.root, "mutable")
    File.mkdir!(parent)
    File.write!(Path.join(parent, "file"), "inside")
    context = %{fixture.context | host: {BoundaryHost, [owner: self()]}}
    task = Task.async(fn -> Tool.execute(context, "read", %{path: "mutable/file"}) end)
    assert_receive {:at_file_boundary, worker}, 5_000
    File.rename!(parent, Path.join(fixture.root, "saved"))
    File.ln_s!(fixture.outside, parent)
    send(worker, :allow)
    assert_reason(Task.await(task, 10_000), :outside_workspace)
  end

  test "write authority is rechecked after approval and rejects the substituted parent",
       fixture do
    parent = Path.join(fixture.root, "mutable")
    File.mkdir!(parent)
    context = %{fixture.context | host: {BoundaryHost, [owner: self()]}}

    task =
      Task.async(fn ->
        Tool.execute(context, "write", %{
          path: "mutable/new",
          snapshot: "missing",
          content: "denied"
        })
      end)

    assert_receive {:at_file_boundary, worker}, 5_000
    File.rename!(parent, Path.join(fixture.root, "saved"))
    File.ln_s!(fixture.outside, parent)
    send(worker, :allow)
    assert_reason(Task.await(task, 10_000), :outside_workspace)
    refute File.exists?(Path.join(fixture.outside, "new"))
  end

  test "Workspace canonicalizes its root and allows only a missing leaf", fixture do
    alias_root = Path.join(fixture.base, "alias-root")
    File.ln_s!(fixture.root, alias_root)
    assert {:ok, root} = Workspace.new(alias_root)
    assert root == fixture.root
    assert {:ok, root} = Workspace.resolve(fixture.context, ".")
    assert root == fixture.root
    assert {:ok, path} = Workspace.resolve(fixture.context, "new", allow_missing: true)
    assert path == Path.join(root, "new")
    assert Workspace.relative(fixture.context, path) == "new"
    assert {:error, :enoent} = Workspace.resolve(fixture.context, "new")

    assert {:error, :enoent} =
             Workspace.resolve(fixture.context, "missing/child", allow_missing: true)

    assert {:error, :outside_workspace} = Workspace.resolve(fixture.context, "../root-other")
    assert {:error, :invalid_path} = Workspace.resolve(fixture.context, <<0>>)
    assert {:error, :missing_context} = Workspace.resolve(%{}, ".")
  end

  test "model-facing string keys and nested edit fields use declared schema conversion",
       fixture do
    File.write!(Path.join(fixture.root, "from-model"), "original")

    params = %{
      "path" => "from-model",
      "snapshot" => sha256("original"),
      "edits" => [%{"old" => "original", "new" => "updated"}]
    }

    assert {:ok, _result, []} =
             Jido.AI.Tools.Executor.execute_module(Edit, params, %{oh_my_jido: fixture.context},
               timeout: 30_000
             )

    assert File.read!(Path.join(fixture.root, "from-model")) == "updated"
  end

  test "a failed edit batch performs no partial mutations and a no-op preserves the inode",
       fixture do
    path = Path.join(fixture.root, "batch")
    File.write!(path, "first second")
    inode = File.stat!(path).inode
    snapshot = sha256("first second")

    assert_reason(
      Tool.execute(fixture.context, "edit", %{
        path: "batch",
        snapshot: snapshot,
        edits: [%{old: "first", new: "changed"}, %{old: "absent", new: "bad"}]
      }),
      :target_not_found
    )

    assert File.read!(path) == "first second"
    assert File.stat!(path).inode == inode

    assert {:ok, result} =
             Tool.execute(fixture.context, "edit", %{
               path: "batch",
               snapshot: snapshot,
               edits: [%{old: "first", new: "first"}]
             })

    refute result.changed
    assert result.bytes_written == 0
    assert result.snapshot == snapshot
    assert File.stat!(path).inode == inode
  end

  test "exact deletion can produce an empty file without changing its mode", fixture do
    path = Path.join(fixture.root, "empty-edit")
    File.write!(path, "α\r\n🙂")
    File.chmod!(path, 0o640)

    assert {:ok, result} =
             Tool.execute(fixture.context, "edit", %{
               path: "empty-edit",
               snapshot: sha256("α\r\n🙂"),
               edits: [%{old: "α\r\n🙂", new: ""}]
             })

    assert result.bytes_written == 0
    assert result.snapshot == sha256("")
    assert File.read!(path) == ""
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o640

    assert {:ok, %{line_count: 0, content: ""}} =
             Tool.execute(fixture.context, "read", %{path: "empty-edit"})
  end

  test "directory reads and broken or cyclic symlinks fail without pretending to be text",
       fixture do
    File.mkdir!(Path.join(fixture.root, "directory"))
    assert_reason(Tool.execute(fixture.context, "read", %{path: "directory"}), :not_regular_file)
    File.ln_s!("absent", Path.join(fixture.root, "broken"))
    assert_reason(Tool.execute(fixture.context, "read", %{path: "broken"}), :enoent)
    File.ln_s!("loop-b", Path.join(fixture.root, "loop-a"))
    File.ln_s!("loop-a", Path.join(fixture.root, "loop-b"))
    assert_reason(Tool.execute(fixture.context, "read", %{path: "loop-a"}), :eloop)
  end

  test "bounded read slices do not retain the discarded large-file binary", fixture do
    content = String.duplicate("x", 1024 * 1024)
    File.write!(Path.join(fixture.root, "large-slice"), content)

    assert {:ok, result} =
             Tool.execute(fixture.context, "read", %{path: "large-slice", max_bytes: 128})

    assert byte_size(result.content) == 128
    assert :binary.referenced_byte_size(result.content) == 128
    assert result.truncated
    assert result.snapshot == sha256(content)
  end

  test "replacement writes with one shared snapshot have exactly one winner", fixture do
    File.write!(Path.join(fixture.root, "write-race"), "original")
    snapshot = sha256("original")

    results =
      ["first", "second"]
      |> Task.async_stream(
        fn content ->
          Tool.execute(fixture.context, "write", %{
            path: "write-race",
            snapshot: snapshot,
            content: content
          })
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    [conflict] = Enum.filter(results, &match?({:error, _}, &1))
    assert_reason(conflict, :stale_snapshot)
    assert File.read!(Path.join(fixture.root, "write-race")) in ["first", "second"]
  end

  test "artifact-only reads reuse confinement without granting ordinary file access", fixture do
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>>
    File.write!(Path.join(fixture.root, "input.png"), bytes)

    context = %{
      fixture.context
      | permissions: MapSet.new([:artifact]),
        tools: [ArtifactRead, Read]
    }

    assert {:ok, result} = Tool.execute(context, "artifact_file_boundary", %{path: "input.png"})
    assert Base.decode64!(result.base64) == bytes
    assert result.snapshot == sha256(bytes)
    assert result.path == "input.png"

    assert_reason(
      Tool.execute(context, "read", %{path: "input.png"}),
      {:permission_denied, :read}
    )

    assert {:error, %{reason: {:permission_denied, :read}}} =
             OhMyJido.Files.read_bytes(context, "input.png", capability: :artifact)

    assert_reason(
      Tool.execute(context, "artifact_file_boundary", %{
        path: Path.join(fixture.outside, "secret.txt")
      }),
      :outside_workspace
    )

    limited = %{context | limits: %{max_file_bytes: 4}}

    assert_reason(
      Tool.execute(limited, "artifact_file_boundary", %{path: "input.png"}),
      :file_too_large
    )
  end

  defp sha256(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp assert_reason({:error, %{details: %{reason: actual}}}, expected),
    do: assert(actual == expected)

  defp assert_reason(other, expected),
    do: flunk("Expected reason #{inspect(expected)}, received #{inspect(other)}")
end
