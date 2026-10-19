defmodule OhMyJido.LSPResultReceiptTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Error
  alias Jido.Action.Error.ExecutionFailureError
  alias OhMyJido.{Context, Files}
  alias OhMyJido.Intelligence.{LSP, Stdio, TextEdits}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    sources = %{
      "sample.ex" => "defmodule Sample do\n  def value(), do: 1\nend\n",
      "consumer.ex" => "defmodule Consumer do\n  def read(), do: Sample.value()\nend\n"
    }

    context = %Context{
      session_id: "lsp-receipt-#{System.unique_integer([:positive])}",
      workspace: root,
      permissions: MapSet.new([:lsp, :read, :edit]),
      host: {__MODULE__.FixtureHost, []},
      limits: %{extension_result_bytes: 65_536}
    }

    for {path, content} <- sources, do: File.write!(Path.join(root, path), content)

    definition = location(context, sources, "sample.ex")
    reference = location(context, sources, "consumer.ex")
    module_definition = location(context, sources, "sample.ex", "Sample", 0)
    module_reference = location(context, sources, "consumer.ex", "Sample")

    File.write!(
      Path.join(root, "native_rename_locations.json"),
      Jason.encode!(%{
        "symbols" => [
          %{"definition" => definition, "references" => [definition, reference]},
          %{
            "definition" => module_definition,
            "references" => [module_definition, module_reference]
          }
        ]
      })
    )

    server =
      start_supervised!(
        {LSP,
         executable: System.find_executable("elixir"),
         args: [Path.expand("support/intelligence_server.ex", __DIR__), "lsp", "native-rename"],
         context: context,
         env: [{"ERL_FLAGS", "+S 2:2 +A 1"}],
         shutdown_timeout_ms: 1_000}
      )

    context = %{context | adapters: %{lsp: {LSP, server: server, rename_backend: :elixir}}}
    assert {:ok, _} = run(context, %{operation: "initialize"})
    assert {:ok, _} = Stdio.await_event(server, "fixture/configurationReady", %{}, 5_000)

    for path <- Enum.sort(Map.keys(sources)) do
      assert {:ok, %{version: 1}} = run(context, %{operation: "open", path: path})
    end

    %{context: context, server: server, sources: sources}
  end

  test "an exact compact-receipt budget retains every completed write and synchronizes the server",
       %{context: context, server: server, sources: sources} do
    renamed = renamed_sources(sources)
    expected = completed_receipt(renamed)
    budget = json_bytes(expected)
    context = with_budget(context, budget)

    assert {:ok, receipt} = run(context, apply_request(sources))
    assert receipt == expected
    assert json_bytes(receipt) == budget
    assert_sources(context, renamed)
    assert_documents(context, server, renamed)
  end

  test "one byte below the full receipt budget rejects before any file is published",
       %{context: context, server: server, sources: sources} do
    budget = json_bytes(completed_receipt(renamed_sources(sources))) - 1
    context = with_budget(context, budget)

    assert {:error, %ExecutionFailureError{}} = run(context, apply_request(sources))
    assert_sources(context, sources)
    assert_documents(context, server, sources)
  end

  test "a bounded synchronization failure retains completed writes and cannot be retried",
       %{context: context, server: server, sources: sources} do
    renamed = renamed_sources(sources)

    expected = %{
      reason: :lsp_rename_sync_failed,
      applied: file_receipts(renamed),
      failure: :protocol_closed,
      effect: :completed,
      backend: :elixir,
      retry: false
    }

    budget = json_bytes(expected)

    context = %{
      with_budget(context, budget)
      | host:
          {__MODULE__.FixtureHost,
           on_write: fn _path ->
             if Process.alive?(server), do: Stdio.close(server, context)
             :ok
           end}
    }

    assert {:error, %ExecutionFailureError{details: receipt} = error} =
             run(context, apply_request(sources))

    assert receipt == expected
    assert json_bytes(receipt) == budget
    refute Error.retryable?(error)
    assert_sources(context, renamed)
  end

  test "a conflict after the first publication retains its exact applied subset and typed failure",
       %{context: context, sources: sources} do
    renamed = renamed_sources(sources)
    concurrent = sources["sample.ex"] <> "# concurrent writer\n"
    budget = 1_024

    context = %{
      with_budget(context, budget)
      | host:
          {__MODULE__.FixtureHost,
           on_write: fn
             "sample.ex" -> File.write!(Path.join(context.workspace, "sample.ex"), concurrent)
             _path -> :ok
           end}
    }

    assert {:error,
            %ExecutionFailureError{
              details:
                %{
                  reason: :workspace_edit_conflict,
                  failed_path: "sample.ex",
                  applied: applied,
                  effect: :uncertain,
                  failure: %{
                    reason: :stale_snapshot,
                    expected_snapshot: expected_snapshot,
                    actual_snapshot: actual_snapshot
                  }
                } = receipt
            } = error} = run(context, apply_request(sources))

    assert applied == Enum.filter(file_receipts(renamed), &(&1.path == "consumer.ex"))
    assert expected_snapshot == Files.snapshot(sources["sample.ex"])
    assert actual_snapshot == Files.snapshot(concurrent)
    assert json_bytes(receipt) <= budget
    refute Error.retryable?(error)
    assert_sources(context, %{"sample.ex" => concurrent, "consumer.ex" => renamed["consumer.ex"]})
  end

  defp completed_receipt(sources) do
    %{applied: true, files: file_receipts(sources), effect: :completed, backend: :elixir}
  end

  defp file_receipts(sources) do
    sources
    |> Enum.sort()
    |> Enum.map(fn {path, content} ->
      %{path: path, snapshot: Files.snapshot(content)}
    end)
  end

  defp renamed_sources(sources),
    do:
      Map.new(sources, fn {path, content} ->
        {path, String.replace(content, "value", "answer")}
      end)

  defp apply_request(sources) do
    snapshots = Map.new(sources, fn {path, content} -> {path, Files.snapshot(content)} end)

    %{
      operation: "rename",
      path: "sample.ex",
      line: 1,
      character: 7,
      new_name: "answer",
      apply: true,
      snapshot: snapshots["sample.ex"],
      snapshots: snapshots
    }
  end

  defp location(context, sources, path, token \\ "value", line_number \\ 1) do
    line = sources[path] |> String.split("\n") |> Enum.at(line_number)
    {character, length} = :binary.match(line, token)
    assert {:ok, uri} = TextEdits.uri(context, path)

    %{
      "uri" => uri,
      "range" => %{
        "start" => %{"line" => line_number, "character" => character},
        "end" => %{"line" => line_number, "character" => character + length}
      }
    }
  end

  defp with_budget(context, budget),
    do: %{context | limits: Map.put(context.limits, :extension_result_bytes, budget)}

  defp json_bytes(value), do: value |> Jason.encode!() |> byte_size()

  defp assert_sources(context, sources) do
    for {path, content} <- sources,
        do: assert(File.read!(Path.join(context.workspace, path)) == content)
  end

  defp assert_documents(context, server, sources) do
    assert {:ok, %{"documents" => documents}} = Stdio.request(server, "fixture/state", %{})

    for {path, content} <- sources do
      assert {:ok, uri} = TextEdits.uri(context, path)
      assert documents[uri] == content
    end
  end

  defp run(context, params) do
    Jido.Exec.run(OhMyJido.Tools.LSP, params, %{oh_my_jido: context},
      max_retries: 0,
      timeout: 15_000
    )
  end

  defmodule FixtureHost do
    @behaviour OhMyJido.Host

    def authorize(_context, :edit, %{operation: :write, path: path}, opts) do
      if callback = opts[:on_write], do: callback.(path)
      :ok
    end

    def authorize(_context, _capability, _effect, _opts), do: :ok
    def credentials(_context, _account, _opts), do: {:error, :not_available}
    def question(_context, _question, _opts), do: {:error, :not_available}

    def invoke(context, capability, request, opts),
      do: OhMyJido.Host.Local.invoke(context, capability, request, opts)
  end
end
