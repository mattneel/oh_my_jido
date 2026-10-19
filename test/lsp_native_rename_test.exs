defmodule OhMyJido.LSPNativeRenameTest do
  use ExUnit.Case, async: false

  alias OhMyJido.{Context, Files}
  alias OhMyJido.Intelligence.{LSP, Stdio, TextEdits}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "oh_my_jido_native_rename_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    context = %Context{
      session_id: "native-rename-#{System.unique_integer([:positive])}",
      workspace: root,
      permissions: MapSet.new([:lsp, :read, :edit]),
      host: {__MODULE__.FixtureHost, []},
      limits: %{extension_result_bytes: 65_536}
    }

    sources = %{
      "sample.ex" =>
        "defmodule Sample do\r\n" <>
          "  def value(), do: 1\r\n" <>
          "  def value(number), do: number\r\n" <>
          "  def twice(), do: value() + value()\r\n" <>
          "  def decorated(), do: {\"😀 value\", value()}\r\n" <>
          "  def one(), do: value(1)\r\n" <>
          "  # value() must not change\r\n" <>
          "end\r\n",
      "consumer.ex" =>
        "defmodule Consumer do\n" <>
          "  def read(), do: Sample.value()\n" <>
          "  def one(), do: Sample.value(1)\n" <>
          "end\n"
    }

    Enum.each(sources, fn {path, source} -> File.write!(Path.join(root, path), source) end)
    manifest = semantic_locations(context, sources)
    File.write!(Path.join(root, "native_rename_locations.json"), Jason.encode!(manifest))

    on_exit(fn -> File.rm_rf!(root) end)
    %{context: context, sources: sources, manifest: manifest}
  end

  test "only trusted configuration selects the planner; absent server rename never triggers fallback",
       %{
         context: context,
         sources: sources
       } do
    {context, server} = start_server(context, rename_backend: :server)
    open_sources(context, sources)
    default = bind_backend(context, server, [])

    assert {:error, {:protocol_error, %{"code" => -32_601}}} = run(default, rename())
    assert {:error, {:protocol_error, %{"code" => -32_601}}} = run(context, rename())
    assert Enum.count(requests(server), &(&1["method"] == "textDocument/rename")) == 2

    native = bind_backend(context, server, rename_backend: :elixir)
    assert {:ok, %{backend: :elixir, applied: false}} = run(native, rename())
    assert Enum.count(requests(server), &(&1["method"] == "textDocument/rename")) == 2
    assert_sources(context, sources)
  end

  test "invalid configured backends and model-selected executors are rejected before requests", %{
    context: context,
    sources: sources
  } do
    {context, server} = start_server(context)
    open_sources(context, sources)
    before = requests(server)

    for backend <- [:unknown, "elixir", nil, {LSP, :invoke}] do
      invalid = bind_backend(context, server, rename_backend: backend)

      assert {:error, {:invalid_lsp_rename_backend, ^backend}} = run(invalid, rename())
    end

    for {field, value} <- [
          {:rename_backend, "server"},
          {:backend, "server"},
          {:executor, "server"},
          {:mfa, "System.cmd"}
        ] do
      assert {:error, _} = run(context, Map.put(rename(), field, value))
    end

    assert requests(server) == before
    assert_sources(context, sources)
  end

  test "read-only preview contains exact UTF-16 source-token edits, current versions and honest evidence",
       %{
         context: context,
         sources: sources,
         manifest: manifest
       } do
    readonly = %{context | permissions: MapSet.new([:lsp, :read])}
    {context, server} = start_server(readonly)
    open_sources(context, sources)

    assert {:ok,
            %{
              applied: false,
              backend: :elixir,
              trusted: false,
              files: files,
              rename_metadata: metadata
            }} = run(context, rename())

    assert metadata.backend == :elixir
    assert metadata.provider == :language_server_definition_references
    assert metadata.certainty == :bounded_source_verified
    assert metadata.symbol.kind == :function
    assert metadata.symbol.name == "value"
    assert metadata.occurrences == 5
    refute Map.has_key?(metadata, :method)

    assert Enum.sort(Enum.map(metadata.scope.inventory, & &1.path)) ==
             Enum.sort(Map.keys(sources))

    [symbol | _] = manifest["symbols"]
    expected = expected_edits(context, symbol["references"], "answer")
    assert Enum.map(files, & &1.path) == Enum.sort(Map.keys(sources))

    for file <- files do
      assert file.snapshot == Files.snapshot(sources[file.path])
      assert file.version == 1
      assert Enum.sort_by(file.edits, & &1["range"]["start"]) == expected[file.path]
      assert {:ok, content} = TextEdits.transform(sources[file.path], file.edits)
      assert content == renamed_sources(sources)[file.path]
    end

    assert Enum.all?(
             Enum.filter(requests(server), &(&1["method"] == "textDocument/references")),
             &(get_in(&1, ["params", "context", "includeDeclaration"]) == true)
           )

    assert_sources(context, sources)
  end

  test "apply requires edit authority and every document snapshot before any publication", %{
    context: context,
    sources: sources
  } do
    {context, server} = start_server(context)
    open_sources(context, sources)
    snapshots = snapshots(sources)
    request = Map.merge(rename(), %{apply: true, snapshot: snapshots["sample.ex"]})
    readonly = %{context | permissions: MapSet.delete(context.permissions, :edit)}
    before = requests(server)

    assert {:error, {:permission_denied, :edit}} = run(readonly, request)
    assert requests(server) == before
    assert {:error, :lsp_snapshot_required} = run(context, request)
    assert_sources(context, sources)

    stale = %{snapshots | "sample.ex" => String.duplicate("0", 64)}
    request = Map.merge(request, %{snapshots: stale, snapshot: stale["sample.ex"]})

    assert {:error, _conflict} = run(context, request)

    assert_sources(context, sources)
  end

  test "current document versions are retained and successful publication resynchronizes every document",
       %{
         context: context,
         sources: sources
       } do
    {context, server} = start_server(context)
    open_sources(context, sources)
    changed = Map.update!(sources, "sample.ex", &(&1 <> "# current disk snapshot\r\n"))
    File.write!(Path.join(context.workspace, "sample.ex"), changed["sample.ex"])

    assert {:ok, %{version: 2}} = run(context, %{operation: "change", path: "sample.ex"})
    assert {:ok, %{files: preview}} = run(context, rename())
    assert Enum.find(preview, &(&1.path == "sample.ex")).version == 2
    assert Enum.find(preview, &(&1.path == "consumer.ex")).version == 1

    assert {:error, :lsp_document_version_stale} =
             run(context, %{operation: "change", path: "sample.ex", version: 2})

    assert {:error, _conflict} = run(context, apply_request(sources))

    assert_sources(context, changed)

    assert {:ok, %{applied: true, backend: :elixir, files: files, rename_metadata: metadata}} =
             run(context, apply_request(changed))

    assert Enum.map(files, & &1.path) == ["consumer.ex", "sample.ex"]
    assert metadata.occurrences == 5
    renamed = renamed_sources(changed)
    assert_sources(context, renamed)
    assert {:ok, state} = Stdio.request(server, "fixture/state", %{})

    for {path, source} <- renamed do
      assert {:ok, uri} = TextEdits.uri(context, path)
      assert state["documents"][uri] == source
      assert state["documentVersions"][uri] == if(path == "sample.ex", do: 3, else: 2)
    end

    refute Enum.any?(requests(server), &(&1["method"] == "textDocument/rename"))
  end

  test "foreign ownership, path escapes and escaped semantic references fail before publication",
       %{
         context: context,
         sources: sources,
         manifest: manifest
       } do
    {context, server} = start_server(context)
    open_sources(context, sources)
    foreign = %{context | session_id: context.session_id <> "-foreign"}
    before = requests(server)
    assert {:error, :protocol_identity_mismatch} = run(foreign, apply_request(sources))

    assert {:error, _} =
             run(context, Map.put(apply_request(sources), :path, "../not-granted.ex"))

    assert requests(server) == before
    [symbol | rest] = manifest["symbols"]
    [location | _] = symbol["references"]
    escaped = %{location | "uri" => "file:///not-granted.ex"}
    symbol = Map.update!(symbol, "references", &(&1 ++ [escaped]))
    manifest = %{manifest | "symbols" => [symbol | rest]}

    File.write!(
      Path.join(context.workspace, "native_rename_locations.json"),
      Jason.encode!(manifest)
    )

    assert {:error, _} = run(context, apply_request(sources))
    assert_sources(context, sources)
  end

  test "completed writes remain reported when the owned server closes before resynchronization",
       %{
         context: context,
         sources: sources
       } do
    {context, server} = start_server(context)
    open_sources(context, sources)

    context = %{
      context
      | host:
          {__MODULE__.FixtureHost,
           on_write: fn ->
             if Process.alive?(server), do: Stdio.close(server, context)
             :ok
           end}
    }

    assert {:error,
            %{
              reason: :lsp_rename_sync_failed,
              effect: :completed,
              failure: :protocol_closed,
              backend: :elixir,
              applied: files,
              rename_metadata: %{backend: :elixir, occurrences: 5}
            }} = run(context, apply_request(sources))

    assert Enum.map(files, & &1.path) == ["consumer.ex", "sample.ex"]
    assert_sources(context, renamed_sources(sources))
  end

  defp start_server(context, opts \\ []) do
    scenario = Keyword.get(opts, :scenario, "native-rename")

    server =
      start_supervised!(
        {LSP,
         [
           executable: System.find_executable("elixir"),
           args: [Path.expand("support/intelligence_server.ex", __DIR__), "lsp", scenario],
           context: context,
           configuration: Keyword.get(opts, :configuration, %{}),
           env: [{"ERL_FLAGS", "+S 2:2 +A 1"}],
           shutdown_timeout_ms: 1_000
         ]}
      )

    context =
      bind_backend(context, server, rename_backend: Keyword.get(opts, :rename_backend, :elixir))

    assert {:ok, _} = run(context, %{operation: "initialize"})

    if scenario == "native-rename" do
      assert {:ok, _} = Stdio.await_event(server, "fixture/configurationReady", %{}, 5_000)
    end

    {context, server}
  end

  defp bind_backend(context, server, opts),
    do: %{context | adapters: %{lsp: {LSP, Keyword.put(opts, :server, server)}}}

  defp open_sources(context, sources) do
    for path <- Enum.sort(Map.keys(sources)) do
      assert {:ok, %{version: 1}} = run(context, %{operation: "open", path: path})
    end
  end

  defp rename do
    %{
      operation: "rename",
      path: "sample.ex",
      line: 1,
      character: 7,
      new_name: "answer",
      apply: false
    }
  end

  defp apply_request(sources) do
    snapshots = snapshots(sources)
    Map.merge(rename(), %{apply: true, snapshot: snapshots["sample.ex"], snapshots: snapshots})
  end

  defp snapshots(sources),
    do: Map.new(sources, fn {path, source} -> {path, Files.snapshot(source)} end)

  defp renamed_sources(sources) do
    %{
      "sample.ex" =>
        sources["sample.ex"]
        |> String.replace("def value()", "def answer()")
        |> String.replace("do: value() + value()", "do: answer() + answer()")
        |> String.replace("\"😀 value\", value()", "\"😀 value\", answer()"),
      "consumer.ex" => String.replace(sources["consumer.ex"], "Sample.value()", "Sample.answer()")
    }
  end

  defp assert_sources(context, sources) do
    for {path, source} <- sources,
        do: assert(File.read!(Path.join(context.workspace, path)) == source)
  end

  defp requests(server) do
    assert {:ok, %{"requests" => requests}} = Stdio.request(server, "fixture/state", %{})
    requests
  end

  defp semantic_locations(context, sources) do
    references = [
      location(context, sources, "sample.ex", "def value()", "value"),
      location(context, sources, "sample.ex", "def twice()", "value", 0),
      location(context, sources, "sample.ex", "def twice()", "value", 1),
      location(context, sources, "sample.ex", "def decorated()", "value", 1),
      location(context, sources, "consumer.ex", "def read()", "value")
    ]

    other_references = [
      location(context, sources, "sample.ex", "def value(number)", "value"),
      location(context, sources, "sample.ex", "def one()", "value"),
      location(context, sources, "consumer.ex", "def one()", "value")
    ]

    module_definition = location(context, sources, "sample.ex", "defmodule", "Sample")

    module_references = [
      module_definition,
      location(context, sources, "consumer.ex", "def read()", "Sample"),
      location(context, sources, "consumer.ex", "def one()", "Sample")
    ]

    %{
      "symbols" => [
        %{"definition" => hd(references), "references" => references},
        %{"definition" => hd(other_references), "references" => other_references},
        %{"definition" => module_definition, "references" => module_references}
      ]
    }
  end

  defp location(context, sources, path, marker, token, occurrence \\ 0) do
    {line, line_number} =
      sources[path]
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.find(fn {line, _number} -> String.contains?(line, marker) end)

    {start, length} = line |> :binary.matches(token) |> Enum.at(occurrence)
    prefix = binary_part(line, 0, start)
    character = div(byte_size(:unicode.characters_to_binary(prefix, :utf8, {:utf16, :little})), 2)
    assert {:ok, uri} = TextEdits.uri(context, path)

    %{
      "uri" => uri,
      "range" => %{
        "start" => %{"line" => line_number, "character" => character},
        "end" => %{"line" => line_number, "character" => character + length}
      }
    }
  end

  defp expected_edits(context, references, name) do
    references
    |> Enum.group_by(fn location ->
      assert {:ok, path} = TextEdits.uri_path(context, location["uri"])
      path
    end)
    |> Map.new(fn {path, locations} ->
      edits =
        locations
        |> Enum.map(&%{"range" => &1["range"], "newText" => name})
        |> Enum.sort_by(& &1["range"]["start"])

      {path, edits}
    end)
  end

  defp run(context, params) do
    OhMyJido.Tools.LSP.run(params, %{oh_my_jido: context})
  end

  defmodule FixtureHost do
    @behaviour OhMyJido.Host

    def authorize(_context, :edit, %{operation: :write}, opts) do
      if callback = opts[:on_write], do: callback.()
      :ok
    end

    def authorize(_context, _capability, _effect, _opts), do: :ok
    def credentials(_context, _account, _opts), do: {:error, :not_available}
    def question(_context, _question, _opts), do: {:error, :not_available}

    def invoke(context, capability, request, opts),
      do: OhMyJido.Host.Local.invoke(context, capability, request, opts)
  end
end
