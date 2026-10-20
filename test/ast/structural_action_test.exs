defmodule OhMyJido.AST.StructuralActionTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Files, Tool, Workspace}
  alias OhMyJido.Tools.AST, as: ASTAction

  defmodule Policy do
    @behaviour OhMyJido.Host

    @impl true
    def authorize(context, capability, effect, opts) do
      if owner = Keyword.get(opts, :owner), do: send(owner, {:ast_authorized, capability, effect})

      cond do
        capability == Keyword.get(opts, :deny) ->
          {:error, {:host_denied, capability}}

        capability == :edit and Keyword.has_key?(opts, :competing_write) ->
          {path, content} = Keyword.fetch!(opts, :competing_write)
          File.write!(path, content)
          :ok

        true ->
          OhMyJido.Host.Local.authorize(context, capability, effect, opts)
      end
    end

    @impl true
    defdelegate credentials(context, account, opts), to: OhMyJido.Host.Local
    @impl true
    defdelegate invoke(context, capability, request, opts), to: OhMyJido.Host.Local
    @impl true
    defdelegate question(context, question, opts), to: OhMyJido.Host.Local
  end

  # The optional adapter performs real Erlang scanning/parsing. It only supports
  # this fixture's call transformation and never performs filesystem mutation.
  defmodule ErlangAdapter do
    def invoke(_context, request, opts) do
      send(Keyword.fetch!(opts, :owner), {:ast_adapter_request, request})

      with "erlang" <- request.language,
           "old(_)" <- request.pattern,
           {:ok, tokens, _location} <-
             :erl_scan.string(String.to_charlist(request.source), {1, 1}, [:text]),
           {:ok, [{:call, _, {:atom, _, :old}, [{:integer, _, value}]}]} <-
             :erl_parse.parse_exprs(tokens) do
        original = "old(#{value})"

        range = %{
          start: %{line: 1, column: 1},
          end: %{line: 1, column: String.length(original) + 1}
        }

        snapshot =
          if Keyword.get(opts, :stale), do: String.duplicate("0", 64), else: request.snapshot

        path = Keyword.get(opts, :path, request.path)

        case request.operation do
          :search ->
            {:ok,
             %{
               path: path,
               snapshot: snapshot,
               matches: [%{range: range, captures: %{"argument" => Integer.to_string(value)}}],
               truncated: false
             }}

          :plan_replace when request.replacement == "new(_)" ->
            {:ok,
             %{
               path: path,
               snapshot: snapshot,
               replacements: [%{range: range, replacement: "new(#{value})"}]
             }}

          _ ->
            {:error, :unsupported_fixture_expression}
        end
      else
        _ -> {:error, :unsupported_fixture_expression}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-ast-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, workspace} = Workspace.new(root)

    context = %Context{
      session_id: "ast-#{System.unique_integer([:positive])}",
      workspace: workspace,
      permissions: MapSet.new([:ast, :read, :edit]),
      tools: [ASTAction]
    }

    %{root: root, context: context}
  end

  test "native Action structurally matches calls and preserves all untouched CRLF and Unicode bytes",
       %{root: root, context: context} do
    source =
      "# untouched: café\r\n" <>
        "defmodule Fixture do\r\n" <>
        "  # IO.inspect(value) in a comment is not a call\r\n" <>
        "  @literal \"IO.inspect(value)\"\r\n" <>
        "  def render(value) do\r\n" <>
        "    left = IO.inspect( value ) # keep this comment\r\n" <>
        "    IO.inspect(value, label: \"untouched\")\r\n" <>
        "    right = IO.inspect(value)\r\n" <>
        "    {left, right}\r\n" <>
        "  end\r\n" <>
        "end\r\n"

    path = Path.join(root, "lib/fixture.ex")
    File.write!(path, source)
    File.chmod!(path, 0o640)

    assert {:ok, search} =
             Tool.execute(context, "ast", %{
               "operation" => "search",
               "path" => "lib/fixture.ex",
               "pattern" => "IO.inspect(value)"
             })

    assert search.path == "lib/fixture.ex"
    assert search.snapshot == Files.snapshot(source)
    refute search.truncated
    assert search.count == 2
    assert Enum.map(search.matches, & &1.source) == ["IO.inspect( value )", "IO.inspect(value)"]
    assert Enum.map(search.matches, & &1.range.start.line) == [6, 8]
    assert Enum.all?(search.matches, &(&1.captures == %{"value" => "value"}))

    assert {:ok, replaced} =
             execute(context, %{
               operation: "replace",
               path: search.path,
               pattern: "IO.inspect(value)",
               replacement: "Logger.debug(value)",
               snapshot: search.snapshot,
               expected_count: 2
             })

    expected =
      source
      |> String.replace("left = IO.inspect( value )", "left = Logger.debug(value)")
      |> String.replace("right = IO.inspect(value)", "right = Logger.debug(value)")

    assert File.read!(path) == expected
    assert replaced.count == 2
    assert replaced.previous_snapshot == search.snapshot
    assert replaced.snapshot == Files.snapshot(expected)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640

    assert {:ok, %{count: 0, matches: []}} =
             execute(context, %{
               operation: "search",
               path: search.path,
               pattern: "IO.inspect(value)"
             })
  end

  test "multiline matches retain exact surrounding bytes and source ranges", %{
    root: root,
    context: context
  } do
    source = "# outside: élève\r\nvalue = IO.inspect(\r\n  \"café\"\r\n) # retain suffix\r\n"
    path = Path.join(root, "lib/multiline.ex")
    File.write!(path, source)

    assert {:ok, search} =
             execute(context, %{
               operation: "search",
               path: "lib/multiline.ex",
               pattern: "IO.inspect(value)"
             })

    assert [%{source: "IO.inspect(\r\n  \"café\"\r\n)", range: range}] = search.matches
    assert range == %{start: %{line: 2, column: 9}, end: %{line: 4, column: 2}}

    assert {:ok, %{count: 1}} =
             execute(context, %{
               operation: "replace",
               path: search.path,
               pattern: "IO.inspect(value)",
               replacement: "Logger.debug(value)",
               snapshot: search.snapshot,
               expected_count: 1
             })

    assert File.read!(path) ==
             "# outside: élève\r\nvalue = Logger.debug(\"café\") # retain suffix\r\n"
  end

  test "returned source ranges select one of several structural matches", %{
    root: root,
    context: context
  } do
    source = "first = IO.inspect(1)\n# keep\nsecond = IO.inspect(2)\n"
    File.write!(Path.join(root, "lib/selected.ex"), source)

    assert {:ok, search} =
             execute(context, %{
               operation: "search",
               path: "lib/selected.ex",
               pattern: "IO.inspect(value)"
             })

    second = Enum.at(search.matches, 1)

    assert {:ok, %{count: 1}} =
             execute(context, %{
               operation: "replace",
               path: search.path,
               pattern: "IO.inspect(value)",
               replacement: "Logger.debug(value)",
               snapshot: search.snapshot,
               ranges: [second.range],
               expected_count: 1
             })

    assert File.read!(Path.join(root, search.path)) ==
             "first = IO.inspect(1)\n# keep\nsecond = Logger.debug(2)\n"
  end

  test "stale searches and replacements reject another writer's snapshot", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "lib/stale.ex")
    File.write!(path, "IO.inspect(1)\n")

    assert {:ok, search} =
             execute(context, %{
               operation: "search",
               path: "lib/stale.ex",
               pattern: "IO.inspect(value)"
             })

    newer = "# another writer\nIO.inspect(2)\n"
    File.write!(path, newer)

    params = %{
      operation: "replace",
      path: search.path,
      pattern: "IO.inspect(value)",
      replacement: "Logger.debug(value)",
      snapshot: search.snapshot,
      expected_count: 1
    }

    result = execute(context, params)
    assert_reason(result, :stale_snapshot)
    assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} = result

    assert error.details == %{
             message: "Structural AST operation rejected: :stale_snapshot",
             reason: :stale_snapshot,
             expected_snapshot: search.snapshot,
             actual_snapshot: Files.snapshot(newer)
           }

    assert error.message == error.details.message
    refute Jido.Action.Error.retryable?(error)
    assert_reason(execute(context, Map.merge(params, %{operation: "search"})), :stale_snapshot)
    assert File.read!(path) == newer
  end

  test "a race at edit approval cannot bypass filesystem publication guards", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "lib/race.ex")
    source = "IO.inspect(1)\n"
    newer = "# host-visible competing writer\nIO.inspect(9)\n"
    File.write!(path, source)
    context = %{context | host: {Policy, [competing_write: {path, newer}]}}

    assert_reason(
      execute(context, %{
        operation: "replace",
        path: "lib/race.ex",
        pattern: "IO.inspect(value)",
        replacement: "Logger.debug(value)",
        snapshot: Files.snapshot(source),
        expected_count: 1
      }),
      :stale_snapshot
    )

    assert File.read!(path) == newer
  end

  test "replacement requires a snapshot and expected count and never silently broadens a target",
       %{root: root, context: context} do
    path = Path.join(root, "lib/count.ex")
    source = "IO.inspect(1)\nIO.inspect(2)\n"
    File.write!(path, source)

    params = %{
      operation: "replace",
      path: "lib/count.ex",
      pattern: "IO.inspect(value)",
      replacement: "Logger.debug(value)"
    }

    assert_reason(execute(context, params), :ast_snapshot_required)

    assert_reason(
      execute(context, Map.put(params, :snapshot, Files.snapshot(source))),
      :ast_expected_count_required
    )

    assert_reason(
      execute(context, Map.merge(params, %{snapshot: Files.snapshot(source), expected_count: 1})),
      :ast_match_count_mismatch
    )

    assert File.read!(path) == source
  end

  test "root confinement rejects traversal, absolute escapes, and symlink escapes", %{
    root: root,
    context: context
  } do
    outside = root <> "-outside.ex"
    File.write!(outside, "IO.inspect(:outside)\n")
    on_exit(fn -> File.rm(outside) end)
    File.ln_s!(outside, Path.join(root, "lib/escape.ex"))

    for path <- ["../#{Path.basename(outside)}", outside, "lib/escape.ex"] do
      assert_reason(
        execute(context, %{operation: "search", path: path, pattern: "IO.inspect(value)"}),
        :outside_workspace
      )

      assert_reason(
        execute(context, %{
          operation: "replace",
          path: path,
          pattern: "IO.inspect(value)",
          replacement: "Logger.debug(value)",
          snapshot: Files.snapshot(File.read!(outside)),
          expected_count: 1
        }),
        :outside_workspace
      )
    end

    assert File.read!(outside) == "IO.inspect(:outside)\n"
  end

  test "AST, read, edit grants and host edit policy are independently enforced", %{
    root: root,
    context: context
  } do
    source = "IO.inspect(1)\n"
    path = Path.join(root, "lib/denied.ex")
    File.write!(path, source)
    search = %{operation: "search", path: "lib/denied.ex", pattern: "IO.inspect(value)"}

    replacement =
      Map.merge(search, %{
        operation: "replace",
        replacement: "Logger.debug(value)",
        snapshot: Files.snapshot(source),
        expected_count: 1
      })

    assert_reason(
      execute(%{context | permissions: MapSet.delete(context.permissions, :ast)}, search),
      {:permission_denied, :ast}
    )

    assert_reason(
      execute(%{context | permissions: MapSet.delete(context.permissions, :read)}, search),
      {:permission_denied, :read}
    )

    assert_reason(
      execute(%{context | permissions: MapSet.delete(context.permissions, :edit)}, replacement),
      {:permission_denied, :edit}
    )

    assert_reason(
      execute(%{context | host: {Policy, [deny: :edit]}}, replacement),
      {:host_denied, :edit}
    )

    assert File.read!(path) == source
  end

  test "bounded search reports truncation while replacement refuses incomplete matches", %{
    root: root,
    context: context
  } do
    source = "IO.inspect(1)\nIO.inspect(2)\nIO.inspect(3)\n"
    path = Path.join(root, "lib/bounded.ex")
    File.write!(path, source)
    context = %{context | limits: %{ast_max_results: 2}}

    params = %{
      operation: "search",
      path: "lib/bounded.ex",
      pattern: "IO.inspect(value)",
      max_results: 10
    }

    assert {:ok, %{count: 2, matches: [_, _], truncated: true}} = execute(context, params)

    assert_reason(
      execute(
        context,
        Map.merge(params, %{
          operation: "replace",
          replacement: "Logger.debug(value)",
          snapshot: Files.snapshot(source),
          expected_count: 3
        })
      ),
      :ast_match_limit
    )

    assert File.read!(path) == source
  end

  test "input and result byte ceilings reject oversized work before mutation", %{
    root: root,
    context: context
  } do
    source = "IO.inspect(\"#{String.duplicate("a", 200)}\")\n"
    path = Path.join(root, "lib/large.ex")
    File.write!(path, source)
    params = %{operation: "search", path: "lib/large.ex", pattern: "IO.inspect(value)"}
    assert_reason(execute(%{context | limits: %{ast_file_bytes: 20}}, params), :file_too_large)

    assert_reason(
      execute(%{context | limits: %{ast_result_bytes: 64}}, params),
      :ast_result_limit
    )

    replacement =
      Map.merge(params, %{
        operation: "replace",
        replacement: "Logger.debug(value)",
        snapshot: Files.snapshot(source),
        expected_count: 1
      })

    assert_reason(
      execute(%{context | limits: %{ast_result_bytes: 64}}, replacement),
      :ast_result_limit
    )

    assert File.read!(path) == source
  end

  test "invalid source and overlapping replacements are explicit and never written", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "lib/invalid.ex")
    File.write!(path, "defmodule Broken do\n")

    result =
      execute(context, %{operation: "search", path: "lib/invalid.ex", pattern: "IO.inspect(_)"})

    assert_reason(result, :ast_parse_error)
    assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} = result
    assert %{reason: :ast_parse_error, description: description} = error.details
    assert is_binary(description) and byte_size(description) > 0
    assert error.message == error.details.message
    assert Jido.Action.Error.to_map(error).details == error.details

    source = "IO.inspect(IO.inspect(1))\n"
    File.write!(path, source)

    assert_reason(
      execute(context, %{
        operation: "replace",
        path: "lib/invalid.ex",
        pattern: "IO.inspect(value)",
        replacement: "Logger.debug(value)",
        snapshot: Files.snapshot(source),
        expected_count: 2
      }),
      :ast_overlapping_replacements
    )

    assert File.read!(path) == source
  end

  test "other languages remain unavailable without an approved AST binding", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "lib/expression.erl"), "old(42).\n")

    assert_reason(
      execute(context, %{
        operation: "search",
        language: "erlang",
        path: "lib/expression.erl",
        pattern: "old(_)"
      }),
      {:capability_unavailable, :ast, "erlang"}
    )
  end

  test "approved AST adapter plans retain snapshot identity and guarded local replacement", %{
    root: root,
    context: context
  } do
    source = "old(42).\n"
    path = Path.join(root, "lib/expression.erl")
    File.write!(path, source)

    context = %{
      context
      | host: {Policy, [owner: self()]},
        adapters: %{ast: {ErlangAdapter, [owner: self()]}}
    }

    search_params = %{
      operation: "search",
      language: "erlang",
      path: "lib/expression.erl",
      pattern: "old(_)"
    }

    assert {:ok, search} = execute(context, search_params)
    assert hd(search.matches).source == "old(42)"
    assert search.snapshot == Files.snapshot(source)

    assert_receive {:ast_adapter_request,
                    %{
                      operation: :search,
                      path: "lib/expression.erl",
                      snapshot: snapshot,
                      source: ^source
                    }}

    assert snapshot == search.snapshot
    assert_receive {:ast_authorized, :ast, _effect}
    assert_receive {:ast_authorized, :read, _effect}

    assert {:ok, %{count: 1}} =
             execute(
               context,
               Map.merge(search_params, %{
                 operation: "replace",
                 replacement: "new(_)",
                 snapshot: search.snapshot,
                 expected_count: 1
               })
             )

    assert_receive {:ast_adapter_request, %{operation: :plan_replace, snapshot: ^snapshot}}
    assert_receive {:ast_authorized, :edit, _effect}
    assert File.read!(path) == "new(42).\n"
  end

  test "adapter snapshot or path mismatches fail closed without writing", %{
    root: root,
    context: context
  } do
    source = "old(42).\n"
    path = Path.join(root, "lib/expression.erl")
    File.write!(path, source)

    params = %{
      operation: "replace",
      language: "erlang",
      path: "lib/expression.erl",
      pattern: "old(_)",
      replacement: "new(_)",
      snapshot: Files.snapshot(source),
      expected_count: 1
    }

    for options <- [[stale: true], [path: "lib/other.erl"]] do
      binding = {ErlangAdapter, [owner: self()] ++ options}

      assert_reason(
        execute(%{context | adapters: %{ast: binding}}, params),
        :ast_adapter_snapshot_mismatch
      )

      assert File.read!(path) == source
    end
  end

  defp execute(context, params) do
    Jido.Exec.run(ASTAction, params, %{oh_my_jido: context}, timeout: 30_000)
  end

  defp assert_reason(result, reason) do
    assert {:error, error} = result
    actual = Jido.Action.Error.to_map(error).details.reason
    assert actual == reason
  end
end
