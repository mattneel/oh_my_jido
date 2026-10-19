defmodule OhMyJido.SearchTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Tool}
  alias OhMyJido.Tools.{List, Search}

  defmodule SwapHost do
    @behaviour OhMyJido.Host

    def authorize(_context, _capability, %{operation: :search_paths}, opts) do
      send(opts[:owner], {:before_discovery, self()})

      receive do
        :allow -> :ok
      after
        5_000 -> {:error, :approval_timeout}
      end
    end

    def authorize(_context, _capability, _effect, _opts), do: :ok
    def credentials(_context, _account, _opts), do: {:error, :credentials_required}

    def invoke(_context, capability, _request, _opts),
      do: {:error, {:capability_unavailable, capability}}

    def question(_context, _question, _opts), do: :pending
  end

  setup do
    base = Path.join(System.tmp_dir!(), "omj-search-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    outside = Path.join(base, "outside")
    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(root, "ignored"))
    File.mkdir_p!(Path.join(root, ".git/info"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    File.write!(Path.join(root, ".gitignore"), "ignored/\n*.tmp\n")
    File.write!(Path.join(root, ".ignore"), "skip.ex\n")
    File.write!(Path.join(root, ".git/info/exclude"), "excluded.ex\n")
    File.write!(Path.join(root, "lib/a.ex"), "def first, do: :needle\nsecond needle\n")
    File.write!(Path.join(root, "lib/nested/b.ex"), "unicode α needle\r\n")
    File.write!(Path.join(root, "lib/space name.ex"), "needle\n")
    File.write!(Path.join(root, "ignored/secret.ex"), "ignored needle")
    File.write!(Path.join(root, "scratch.tmp"), "temporary needle")
    File.write!(Path.join(root, "skip.ex"), "skip needle")
    File.write!(Path.join(root, "excluded.ex"), "excluded needle")
    File.write!(Path.join(root, ".hidden/private.ex"), "hidden needle")
    File.write!(Path.join(root, "binary.ex"), <<0, 255, 110, 101, 101, 100, 108, 101>>)
    File.write!(Path.join(outside, "secret.ex"), "outside needle")
    File.ln_s!(outside, Path.join(root, "escape"))
    File.ln_s!(Path.join(outside, "secret.ex"), Path.join(root, "escape.ex"))
    on_exit(fn -> File.rm_rf!(base) end)

    context = %Context{
      session_id: "search-test",
      workspace: root,
      permissions: MapSet.new([:read]),
      tools: [Search, List]
    }

    %{root: root, outside: outside, context: context}
  end

  test "glob listing returns stable relative paths and honors workspace ignore files", fixture do
    assert {:ok, result} = Tool.execute(fixture.context, "list", %{glob: "lib/**/*.ex"})
    assert result.paths == ["lib/a.ex", "lib/nested/b.ex", "lib/space name.ex"]
    assert result.count == 3
    refute result.truncated
    assert result.path == "."

    assert {:ok, all} = Tool.execute(fixture.context, "list", %{})
    refute Enum.any?(all.paths, &String.starts_with?(&1, "ignored/"))
    refute "scratch.tmp" in all.paths
    refute "skip.ex" in all.paths
    refute "excluded.ex" in all.paths
    refute Enum.any?(all.paths, &String.starts_with?(&1, ".hidden/"))
    refute Enum.any?(all.paths, &String.starts_with?(&1, "escape/"))
    refute "escape.ex" in all.paths
  end

  test "literal search reads actual files with accurate line and byte-column positions",
       fixture do
    assert {:ok, result} =
             Tool.execute(fixture.context, "search", %{pattern: "needle", glob: "lib/**/*.ex"})

    assert Enum.map(result.matches, &{&1.path, &1.line, &1.column, &1.text}) == [
             {"lib/a.ex", 1, 17, "def first, do: :needle"},
             {"lib/a.ex", 2, 8, "second needle"},
             {"lib/nested/b.ex", 1, 12, "unicode α needle"},
             {"lib/space name.ex", 1, 1, "needle"}
           ]

    assert result.count == 4
    refute result.truncated
    assert result.skipped.binary == 0
    assert Enum.all?(result.matches, &String.valid?(&1.text))
  end

  test "regex and case-insensitive literal modes do not become shell arguments", fixture do
    assert {:ok, regex} =
             Tool.execute(fixture.context, "search", %{
               pattern: "second\\s+needle",
               mode: "regex",
               glob: "lib/**/*.ex"
             })

    assert [%{path: "lib/a.ex", line: 2}] = regex.matches

    assert {:ok, insensitive} =
             Tool.execute(fixture.context, "search", %{
               pattern: "NEEDLE",
               case_sensitive: false,
               glob: "lib/space name.ex"
             })

    assert [%{path: "lib/space name.ex"}] = insensitive.matches

    assert_reason(
      Tool.execute(fixture.context, "search", %{pattern: "[", mode: "regex"}),
      :invalid_pattern
    )

    assert {:ok, literal} =
             Tool.execute(fixture.context, "search", %{pattern: "$(touch injected); --help"})

    assert literal.matches == []
    refute File.exists?(Path.join(fixture.root, "injected"))
  end

  test "binary and oversize files are skipped explicitly without leaking escaped contents",
       fixture do
    File.write!(Path.join(fixture.root, "oversize.ex"), String.duplicate("needle ", 100))
    context = %{fixture.context | limits: %{max_file_bytes: 128}}
    assert {:ok, result} = Tool.execute(context, "search", %{pattern: "needle", glob: "*.ex"})
    assert result.skipped.binary == 1
    assert result.skipped.large == 1
    refute Enum.any?(result.matches, &(&1.path == "escape.ex"))
    refute inspect(result) =~ "outside needle"
  end

  test "result and output bounds are enforced and truncation is reported", fixture do
    assert {:ok, listing} =
             Tool.execute(fixture.context, "list", %{glob: "lib/**/*.ex", max_results: 2})

    assert listing.paths == ["lib/a.ex", "lib/nested/b.ex"]
    assert listing.truncated
    assert listing.truncation.results

    assert {:ok, search} =
             Tool.execute(fixture.context, "search", %{
               pattern: "needle",
               glob: "lib/**/*.ex",
               max_results: 2
             })

    assert search.count == 2
    assert search.truncated
    assert search.truncation.results
    assert Enum.map(search.matches, & &1.path) == ["lib/a.ex", "lib/a.ex"]

    context = %{fixture.context | limits: %{search_max_results: 1, search_max_output_bytes: 100}}

    assert {:ok, bounded} =
             Tool.execute(context, "search", %{
               pattern: "needle",
               max_results: 100,
               max_bytes: 10_000
             })

    assert bounded.count <= 1
    assert bounded.truncated
  end

  test "line output bounds preserve valid UTF-8 and advertise partial text", fixture do
    File.write!(Path.join(fixture.root, "long.ex"), "🙂🙂🙂 needle\n")

    assert {:ok, result} =
             Tool.execute(fixture.context, "search", %{
               pattern: "needle",
               glob: "long.ex",
               max_line_bytes: 5
             })

    assert [%{text: "🙂", text_truncated: true, column: 14}] = result.matches
    assert result.truncated
    assert result.truncation.lines
  end

  test "subdirectory listing keeps paths relative to the workspace", fixture do
    assert {:ok, result} =
             Tool.execute(fixture.context, "list", %{path: "lib/nested", glob: "*.ex"})

    assert result.paths == ["lib/nested/b.ex"]
    assert result.path == "lib/nested"

    assert {:ok, result} =
             Tool.execute(fixture.context, "search", %{
               path: "lib/nested",
               pattern: "needle",
               glob: "*.ex"
             })

    assert [%{path: "lib/nested/b.ex"}] = result.matches
  end

  test "explicit hidden and ignore overrides never include git internals or symlink escapes",
       fixture do
    assert {:ok, hidden} = Tool.execute(fixture.context, "list", %{hidden: true, glob: "**/*.ex"})
    assert ".hidden/private.ex" in hidden.paths
    refute "ignored/secret.ex" in hidden.paths

    assert {:ok, all} = Tool.execute(fixture.context, "list", %{hidden: true, ignore: false})
    assert "ignored/secret.ex" in all.paths
    assert "skip.ex" in all.paths
    assert "excluded.ex" in all.paths
    refute Enum.any?(all.paths, &String.starts_with?(&1, ".git/"))
    refute "escape.ex" in all.paths
  end

  test "permission denials and unsafe glob patterns fail before discovery", fixture do
    context = %{fixture.context | permissions: MapSet.new()}
    assert_reason(Tool.execute(context, "list", %{}), {:permission_denied, :read})

    assert_reason(
      Tool.execute(context, "search", %{pattern: "needle"}),
      {:permission_denied, :read}
    )

    for glob <- ["../outside/*.ex", "/**/*.ex"] do
      assert_reason(Tool.execute(fixture.context, "list", %{glob: glob}), :outside_workspace)

      assert_reason(
        Tool.execute(fixture.context, "search", %{pattern: "needle", glob: glob}),
        :outside_workspace
      )
    end
  end

  test "out-of-root ignore-rule symlinks are rejected before ripgrep can read them", fixture do
    rule = Path.join(fixture.root, ".ignore")
    File.rm!(rule)
    File.ln_s!(Path.join(fixture.outside, "secret.ex"), rule)
    assert_reason(Tool.execute(fixture.context, "list", %{}), :outside_workspace)

    assert_reason(
      Tool.execute(fixture.context, "search", %{pattern: "needle"}),
      :outside_workspace
    )
  end

  test "ignore-rule confinement is rechecked after process approval", fixture do
    context = %{fixture.context | host: {SwapHost, [owner: self()]}}
    task = Task.async(fn -> Tool.execute(context, "list", %{}) end)
    assert_receive {:before_discovery, worker}, 5_000
    rule = Path.join(fixture.root, ".ignore")
    File.rm!(rule)
    File.ln_s!(Path.join(fixture.outside, "secret.ex"), rule)
    send(worker, :allow)
    assert_reason(Task.await(task, 10_000), :outside_workspace)
  end

  test "Git ignore-directory indirections cannot grant a second filesystem root", fixture do
    git = Path.join(fixture.root, ".git")
    File.rename!(git, Path.join(fixture.root, ".git-saved"))
    File.write!(git, "gitdir: #{fixture.outside}\n")
    assert_reason(Tool.execute(fixture.context, "list", %{}), :outside_workspace)
  end

  test "discovery and scan budgets never masquerade as a complete empty result", fixture do
    discovery = %{fixture.context | limits: %{search_max_discovery_bytes: 5}}
    assert {:ok, listed} = Tool.execute(discovery, "list", %{glob: "lib/**/*.ex"})
    assert listed.truncated
    assert listed.truncation.enumeration

    scan = %{fixture.context | limits: %{search_max_scan_bytes: 1}}
    assert {:ok, result} = Tool.execute(scan, "search", %{pattern: "needle"})
    assert result.matches == []
    assert result.truncated
    assert result.truncation.files
  end

  defp assert_reason({:error, %{details: %{reason: actual}}}, expected),
    do: assert(actual == expected)

  defp assert_reason(other, expected),
    do: flunk("Expected reason #{inspect(expected)}, received #{inspect(other)}")
end
