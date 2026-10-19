defmodule OhMyJido.IntelligenceTextEditsTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Files}
  alias OhMyJido.Intelligence.{Framing, TextEdits}

  test "UTF-16 positions preserve Unicode and CRLF bytes outside the edit" do
    source = "a😀b\r\nkeep\r\n"

    edit = %{
      "range" => %{
        "start" => %{"line" => 0, "character" => 3},
        "end" => %{"line" => 0, "character" => 4}
      },
      "newText" => "c"
    }

    assert {:ok, "a😀c\r\nkeep\r\n"} = TextEdits.transform(source, [edit])
    split = put_in(edit["range"]["start"]["character"], 2)
    assert {:error, :lsp_surrogate_split} = TextEdits.transform(source, [split])

    carriage_return = %{
      "range" => %{
        "start" => %{"line" => 1, "character" => 0},
        "end" => %{"line" => 1, "character" => 1}
      },
      "newText" => "c"
    }

    assert {:ok, "a\rc"} = TextEdits.transform("a\rb", [carriage_return])
  end

  @tag :protocol_repair
  test "coincident insertions retain server order across a UTF-16 position" do
    insertion = fn text ->
      %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 2},
          "end" => %{"line" => 0, "character" => 2}
        },
        "newText" => text
      }
    end

    assert {:ok, "😀ABtail"} =
             TextEdits.transform("😀tail", [insertion.("A"), insertion.("B")])
  end

  @tag :protocol_repair
  test "ordered insertions can precede a replacement at the same start without allowing overlap" do
    edit = fn ending, text ->
      %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 1},
          "end" => %{"line" => 0, "character" => ending}
        },
        "newText" => text
      }
    end

    assert {:ok, "aABRdef"} =
             TextEdits.transform("abcdef", [edit.(1, "A"), edit.(1, "B"), edit.(3, "R")])

    assert {:error, :lsp_overlapping_edits} =
             TextEdits.transform("abcdef", [edit.(3, "R"), edit.(1, "A")])

    assert {:error, :lsp_overlapping_edits} =
             TextEdits.transform("abcdef", [edit.(3, "R"), edit.(4, "S")])
  end

  @tag :protocol_repair
  @tag :tmp_dir
  test "versioned plans require their bound document version while null versions use disk snapshots",
       %{tmp_dir: root} do
    path = Path.join(root, "versioned.ex")
    File.write!(path, "before\n")

    context = %Context{
      session_id: "versioned-edit-policy",
      workspace: root,
      permissions: MapSet.new([:read, :edit])
    }

    assert {:ok, uri} = TextEdits.uri(context, "versioned.ex")

    text_edit = %{
      "range" => %{
        "start" => %{"line" => 0, "character" => 0},
        "end" => %{"line" => 0, "character" => 6}
      },
      "newText" => "after"
    }

    workspace_edit = %{
      "documentChanges" => [
        %{"textDocument" => %{"uri" => uri, "version" => 1}, "edits" => [text_edit]}
      ]
    }

    snapshots = %{"versioned.ex" => Files.snapshot("before\n")}
    assert {:ok, plans} = TextEdits.plan(context, workspace_edit, snapshots)
    assert {:error, _} = TextEdits.apply(context, plans)
    assert {:error, _} = TextEdits.apply(context, plans, %{uri => 2})
    assert File.read!(path) == "before\n"
    assert {:ok, _} = TextEdits.apply(context, plans, %{uri => 1})
    assert File.read!(path) == "after\n"

    File.write!(path, "before\n")
    [document_change] = workspace_edit["documentChanges"]
    document_change = put_in(document_change["textDocument"]["version"], nil)

    assert {:ok, plans} =
             TextEdits.plan(context, %{"documentChanges" => [document_change]}, snapshots)

    assert {:ok, _} = TextEdits.apply(context, plans)
    assert File.read!(path) == "after\n"
  end

  test "overlap, out-of-range positions and non-text resource commands fail closed" do
    edit = %{
      "range" => %{
        "start" => %{"line" => 0, "character" => 0},
        "end" => %{"line" => 0, "character" => 2}
      },
      "newText" => "ok"
    }

    assert {:error, :lsp_overlapping_edits} = TextEdits.transform("abc", [edit, edit])
    assert {:error, :lsp_position_out_of_bounds} = TextEdits.transform("a", [edit])

    context = %Context{
      session_id: "edit-policy",
      workspace: System.tmp_dir!(),
      permissions: MapSet.new([:read])
    }

    assert {:error, :lsp_resource_operation_not_granted} =
             TextEdits.plan(
               context,
               %{"documentChanges" => [%{"kind" => "delete", "uri" => "file:///not-granted"}]},
               %{}
             )
  end

  test "header framing accepts split UTF-8 bodies and adjacent messages, bounded by encoded bytes" do
    message = %{"jsonrpc" => "2.0", "id" => 1, "result" => "😀"}
    assert {:ok, encoded} = Framing.encode(message, :headers, 1_024)
    bytes = IO.iodata_to_binary(encoded)
    split_at = byte_size(bytes) - 3
    first = binary_part(bytes, 0, split_at)
    last = binary_part(bytes, split_at, byte_size(bytes) - split_at)
    assert {:ok, [], ^first} = Framing.decode(first, :headers, 1_024)

    assert {:ok, [^message, ^message], ""} =
             Framing.decode(first <> last <> bytes, :headers, 1_024)

    assert {:error, :protocol_message_too_large} = Framing.decode(bytes, :headers, 1)

    assert {:error, :invalid_content_length} =
             Framing.decode("Content-Length: 1\r\nContent-Length: 1\r\n\r\n{}", :headers, 1_024)

    assert {:error, :invalid_protocol_json} =
             Framing.decode("Content-Length: 2\r\n\r\n[]", :headers, 1_024)
  end

  test "MCP newline framing bounds incomplete messages and rejects non-objects" do
    assert {:ok, [%{"id" => 1}], ""} = Framing.decode("{\"id\":1}\n", :lines, 100)

    assert {:error, :protocol_message_too_large} =
             Framing.decode(String.duplicate("x", 101), :lines, 100)

    assert {:error, :invalid_protocol_json} = Framing.decode("true\n", :lines, 100)
  end
end
