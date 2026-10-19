defmodule OhMyJido.ElixirRenameTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Files}
  alias OhMyJido.Intelligence.{ElixirRename, TextEdits}
  alias OhMyJido.Intelligence.ElixirRename.{Bindings, Source}

  setup do
    root = Path.join(System.tmp_dir!(), "omj-elixir-rename-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    context = %Context{
      session_id: "rename-#{System.unique_integer([:positive])}",
      workspace: root,
      permissions: MapSet.new([:read, :lsp]),
      host: {__MODULE__.Host, []}
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{context: context, root: root}
  end

  test "a default/multiclause family follows cross-file native identity, pipes, captures and import arities",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups)
    before = contents(fixture, files)
    request = function_request(files, "multiply")

    assert {:ok, edit, metadata} = ElixirRename.plan(fixture.context, server, request, [])
    assert metadata.backend == :elixir
    assert metadata.certainty == :bounded_source_verified
    assert metadata.symbol.arities == [1, 2]
    assert metadata.occurrences == 11
    assert metadata.scope.complete
    assert metadata.native_inputs.source_fingerprints_verified
    assert metadata.native_inputs.synchronized == []
    assert GenServer.call(server, :notifications) == []
    assert Enum.map(metadata.scope.inventory, & &1.path) == ["math.ex", "other.ex", "user.ex"]
    assert Enum.all?(edit["documentChanges"], &(&1["textDocument"]["version"] == 7))
    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
    rendered = Map.new(plans, &{&1.path, &1.content})

    assert rendered["math.ex"] ==
             String.replace(
               files["math.ex"],
               ["def product(x, y", "def product(0, _y)", "do: product(x)"],
               fn
                 "def product(x, y" -> "def multiply(x, y"
                 "def product(0, _y)" -> "def multiply(0, _y)"
                 "do: product(x)" -> "do: multiply(x)"
               end
             )

    assert rendered["user.ex"] =~ "only: [multiply: 1, multiply: 2, product: 3]"
    assert rendered["user.ex"] =~ "M.multiply(x)"
    assert rendered["user.ex"] =~ "multiply(x, 3)"
    assert rendered["user.ex"] =~ "x |> multiply()"
    assert rendered["user.ex"] =~ "{&M.multiply/1, &multiply/2}"
    assert rendered["user.ex"] =~ "M.product(1, 2, 3)"
    assert rendered["user.ex"] =~ "\"😀 product\""
    assert rendered["user.ex"] =~ "# product stays a comment\r\n"
    refute Map.has_key?(rendered, "other.ex")
    assert before == contents(fixture, files)
  end

  test "multiple native definition locations must belong to the same authored default family",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups, mode: :all_clauses)

    assert {:ok, _edit, %{symbol: %{arities: [1, 2]}, occurrences: 11}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "an import qualifier can select its native module's default family even though key definitions are nil",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups)
    request = request(files, "user.ex", "product: 1", "multiply", 0, byte_size("product"))

    assert {:ok, _edit, %{symbol: %{arities: [1, 2]}, occurrences: 11}} =
             ElixirRename.plan(fixture.context, server, request, [])
  end

  test "scoped native variable versions preserve rebinding, anonymous shadowing, captures and pins",
       fixture do
    {files, groups} = variable_project()
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{symbol: %{kind: :variable}, occurrences: 3}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "vars.ex", "value", "input"),
               []
             )

    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
    assert plan.content =~ "def run(input)"
    assert plan.content =~ "first = input"
    assert plan.content =~ "value = input + 1"
    assert plan.content =~ "fn value -> value + 10 end"
    assert plan.content =~ "fn -> value end"
    assert plan.content =~ "^value -> value"

    assert {:ok, edit, %{occurrences: 5}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "vars.ex", "value", "updated", 2),
               []
             )

    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
    refute plan.content =~ "value = value + 1"
    assert plan.content =~ "updated = value + 1"
    assert plan.content =~ "fn value -> value + 10 end"
    assert plan.content =~ "fn -> updated end"
    assert plan.content =~ "^updated -> updated"
    assert plan.content =~ "{first, updated, nested, captured}"
    assert File.read!(Path.join(fixture.root, "vars.ex")) == files["vars.ex"]
  end

  test "module leaf rename preserves explicit aliases, updates implicit aliases, and uses zero-width native anchors",
       fixture do
    {files, groups} = module_project()
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{symbol: %{kind: :module, new_name: "NewName"}, occurrences: 5}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "old.ex", "OldName", "NewName"),
               []
             )

    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
    rendered = Map.new(plans, &{&1.path, &1.content})
    assert rendered["old.ex"] =~ "defmodule NewName"
    assert rendered["old.ex"] =~ "def self(), do: __MODULE__"
    assert rendered["uses.ex"] =~ "alias NewName\n"
    assert rendered["uses.ex"] =~ "NewName.value()"
    assert rendered["uses.ex"] =~ "alias NewName, as: Stable"
    assert rendered["uses.ex"] =~ "Stable.value()"
    assert rendered["uses.ex"] =~ "require NewName, as: Required"
    assert rendered["uses.ex"] =~ "Required.value()"
    assert rendered["uses.ex"] =~ "\"OldName Stable\""
    assert File.read!(Path.join(fixture.root, "old.ex")) == files["old.ex"]
  end

  test "nested module declarations use exact native workspace symbols when definitions are absent",
       fixture do
    {files, groups} = nested_module_index_project()
    install(fixture, files)

    for mode <- [:module_declaration_index, :empty_module_declaration_index] do
      server = provider(fixture, files, groups, mode: mode)

      assert {:ok, edit, _metadata} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "outer.ex", "Old do", "New", 0, 3),
                 []
               )

      assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})

      assert Map.new(plans, &{&1.path, &1.content}) == %{
               "outer.ex" =>
                 files["outer.ex"]
                 |> String.replace("defmodule Old", "defmodule New")
                 |> String.replace("Old.value()", "Elixir.Outer.New.value()"),
               "caller.ex" =>
                 String.replace(
                   files["caller.ex"],
                   "Outer.Old.value()",
                   "Elixir.Outer.New.value()"
                 )
             }

      assert GenServer.call(server, :notifications) == []
      assert contents(fixture, files) == files
    end
  end

  test "workspace symbols cannot lend a nested module another name, file or declaration range",
       fixture do
    {files, groups} = nested_module_index_project()
    install(fixture, files)

    symbol = %{
      "name" => "Outer.Old",
      "kind" => 2,
      "location" => %{
        "uri" => uri(fixture.root, "outer.ex"),
        "range" => %{
          "start" => %{"line" => 1, "character" => 0},
          "end" => %{"line" => 2, "character" => 0}
        }
      }
    }

    other_declaration = %{
      "start" => %{"line" => 0, "character" => 0},
      "end" => %{"line" => 1, "character" => 0}
    }

    for symbols <- [
          [Map.put(symbol, "name", "Other.Old")],
          [put_in(symbol, ["location", "uri"], uri(fixture.root, "caller.ex"))],
          [put_in(symbol, ["location", "uri"], "file:///fixture-sdk/outer.ex")],
          [put_in(symbol, ["location", "range"], other_declaration)],
          [put_in(symbol, ["location", "range", "start", "line"], 0)],
          [Map.put(symbol, "kind", 12)],
          [put_in(symbol, ["location", "range"], %{"start" => %{"line" => 1, "character" => 0}})],
          [],
          %{"items" => [symbol]},
          List.duplicate(symbol, 1_001)
        ] do
      server =
        provider(fixture, files, groups,
          mode: :module_declaration_index,
          workspace_symbols: symbols
        )

      assert {:error, _reason} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "outer.ex", "Old do", "New", 0, 3),
                 []
               )

      assert contents(fixture, files) == files
    end
  end

  test "module symbol fallback cannot repair malformed definitions or unaudited SDK profiles",
       fixture do
    {files, groups} = nested_module_index_project()
    install(fixture, files)

    for opts <- [
          [mode: :malformed_definition],
          [
            mode: :module_declaration_index,
            server_info: %{"name" => "Other", "version" => "0.31.1"}
          ],
          [
            mode: :module_declaration_index,
            server_info: %{"name" => "ElixirLS", "version" => "0.32.0"}
          ],
          [mode: :module_declaration_index, server_info: nil]
        ] do
      server = provider(fixture, files, groups, opts)

      assert {:error, _reason} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "outer.ex", "Old do", "New", 0, 3),
                 []
               )

      assert contents(fixture, files) == files
    end
  end

  test "implicit module aliases cannot capture untouched destination receivers or descendants",
       fixture do
    for destination <- ["New", "New.Child"] do
      consumer = """
      defmodule Consumer do
        alias Origin.Old
        def selected(), do: Old.value()
        def unrelated(), do: #{destination}.value()
      end
      """

      {files, groups} = module_alias_capture_project(consumer, destination, "Old")
      install(fixture, files)
      server = provider(fixture, files, groups)

      assert {:error, :elixir_rename_destination_alias_capture} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "consumer.ex", "Old.value", "New", 0, 3),
                 []
               )

      assert contents(fixture, files) == files
    end
  end

  test "nested module declarations cannot introduce capturing aliases in their enclosing scope",
       fixture do
    for {declaration, destination, outcome} <- [
          {"Old", "New", :capture},
          {"Old", "New.Child", :capture},
          {"Old", "Elixir.New", :ok},
          {"Outer.Old", "Elixir.New", :unsupported}
        ] do
      destination_module = String.trim_leading(destination, "Elixir.")
      selected = if declaration == "Old", do: "Old", else: "Outer.Old"

      files = %{
        "new.ex" => "defmodule #{destination_module} do\n  def value(), do: :unrelated\nend\n",
        "outer.ex" => """
        defmodule Outer do
          defmodule #{declaration} do
            def value(), do: :old
          end
          def selected(), do: #{selected}.value()
          def unrelated(), do: #{destination}.value()
        end
        """,
        "caller.ex" =>
          "defmodule NestedCaller do\n  def selected(), do: Outer.Old.value()\nend\n",
        "untouched.ex" => """
        defmodule Untouched do
          defmodule New do
            def value(), do: :nested
          end
          def preserved(), do: New.value()
        end
        """
      }

      old = token(files, "outer.ex", declaration <> " do", 0, byte_size(declaration))
      unrelated = token(files, "new.ex", destination_module)
      untouched = token(files, "untouched.ex", "New do", 0, 3)

      identities = [
        {old,
         [
           token(files, "outer.ex", selected <> ".value", 0, byte_size(selected)),
           token(files, "caller.ex", "Outer.Old")
         ]},
        {unrelated,
         [token(files, "outer.ex", destination <> ".value", 0, byte_size(destination))]},
        {untouched, [token(files, "untouched.ex", "New.value", 0, 3)]},
        {token(files, "outer.ex", "Outer"), []},
        {token(files, "caller.ex", "NestedCaller"), []},
        {token(files, "untouched.ex", "Untouched"), []}
      ]

      groups =
        Enum.map(identities, fn {definition, references} ->
          members = [definition | references]
          %{definition: definition, members: members, references: members}
        end)

      install(fixture, files)
      server = provider(fixture, files, groups)

      result =
        ElixirRename.plan(
          fixture.context,
          server,
          request(files, "outer.ex", selected <> ".value", "New", 0, byte_size(selected)),
          []
        )

      case outcome do
        :capture ->
          assert {:error, :elixir_rename_destination_alias_capture} = result

        :unsupported ->
          assert {:error, :elixir_rename_nested_module_alias_binding_unsupported} = result

        :ok ->
          assert {:ok, edit, _metadata} = result
          assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
          rendered = Map.new(plans, &{&1.path, &1.content})

          assert rendered["outer.ex"] ==
                   files["outer.ex"]
                   |> String.replace("defmodule Old", "defmodule New")
                   |> String.replace("Old.value()", "Elixir.Outer.New.value()")

          assert rendered["caller.ex"] =~ "Elixir.Outer.New.value()"
          refute Map.has_key?(rendered, "new.ex")
          refute Map.has_key?(rendered, "untouched.ex")
      end

      assert contents(fixture, files) == files
    end
  end

  test "module alias capture checks respect explicit names, absolute receivers, scopes and rebinding",
       fixture do
    cases = [
      {"New", "Stable", [{"New", 0}],
       """
       defmodule Consumer do
         alias New
         alias Origin.Old, as: Stable
         def selected(), do: Stable.value()
         def unrelated(), do: New.value()
       end
       """},
      {"Elixir.New", "Old", [],
       """
       defmodule Consumer do
         alias Origin.Old
         def selected(), do: Old.value()
         def unrelated(), do: Elixir.New.value()
       end
       """},
      {"New", "Old", [{"New", 0}],
       """
       defmodule Consumer do
         def unrelated() do
           alias New
           New.value()
         end
         def selected() do
           alias Origin.Old
           Old.value()
         end
       end
       """},
      {"New", "Old", [{"Elixir.New", 0}],
       """
       defmodule Consumer do
         alias Origin.Old
         def selected(), do: Old.value()
         def unrelated() do
           alias Elixir.New
           New.value()
         end
       end
       """}
    ]

    for {destination, selected, aliases, consumer} <- cases do
      {files, groups} = module_alias_capture_project(consumer, destination, selected, aliases)
      install(fixture, files)
      server = provider(fixture, files, groups)

      assert {:ok, edit, _metadata} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(
                   files,
                   "consumer.ex",
                   selected <> ".value",
                   "New",
                   0,
                   byte_size(selected)
                 ),
                 []
               )

      assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
      rendered = Map.new(plans, &{&1.path, &1.content})
      receiver = if selected == "Stable", do: selected, else: "New"

      assert rendered["consumer.ex"] ==
               consumer
               |> String.replace("Origin.Old", "Origin.New")
               |> String.replace(selected <> ".value()", receiver <> ".value()")

      assert rendered["old.ex"] == String.replace(files["old.ex"], "Origin.Old", "Origin.New")
      refute Map.has_key?(rendered, "new.ex")
      assert contents(fixture, files) == files
    end
  end

  test "fully qualified module uses remain safe inside an ordinary ExUnit use scope", fixture do
    {files, groups} = module_project()

    files =
      Map.put(
        files,
        "behavior_test.exs",
        "defmodule RenameBehaviorTest do\n  use ExUnit.Case\n  test \"value\" do\n    assert OldName.value() == 1\n  end\nend\n"
      )

    reference = token(files, "behavior_test.exs", "OldName")

    groups =
      List.update_at(
        groups,
        0,
        &%{&1 | members: [reference | &1.members], references: [reference | &1.references]}
      )

    test_module = token(files, "behavior_test.exs", "RenameBehaviorTest")

    sdk = %{
      "uri" => "file:///fixture-sdk/ex_unit/case.ex",
      "range" => %{
        "start" => %{"line" => 0, "character" => 0},
        "end" => %{"line" => 500, "character" => 3}
      }
    }

    groups =
      groups ++
        [
          %{definition: test_module, members: [test_module], references: [test_module]},
          %{
            definition: sdk,
            members: [token(files, "behavior_test.exs", "ExUnit.Case")],
            references: []
          }
        ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{symbol: %{native_namespace: %{raw_is_incomplete: true}}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "old.ex", "OldName", "NewName"),
               []
             )

    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})

    assert Enum.find(plans, &(&1.path == "behavior_test.exs")).content =~
             "assert Elixir.NewName.value() == 1"

    assert Enum.find(plans, &(&1.path == "uses.ex")).content =~ "Stable.value()"
    assert contents(fixture, files) == files
  end

  test "SDK namespace occupancy, incomplete catalogs and unsupported formatter identities reject module publication",
       fixture do
    {files, groups} = module_project()
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, :elixir_rename_destination_module_exists} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "old.ex", "OldName", "Enum"),
               []
             )

    missing = provider(fixture, files, groups, mode: :malformed_completion)

    assert {:error, :elixir_rename_native_namespace_evidence_incomplete} =
             ElixirRename.plan(
               fixture.context,
               missing,
               request(files, "old.ex", "OldName", "NewName"),
               []
             )

    too_many = provider(fixture, files, groups, mode: :namespace_limit)

    assert {:error, :elixir_rename_native_namespace_limit} =
             ElixirRename.plan(
               fixture.context,
               too_many,
               request(files, "old.ex", "OldName", "NewName"),
               []
             )

    unknown =
      provider(fixture, files, groups, server_info: %{"name" => "Other", "version" => "0.31.1"})

    assert {:error, :elixir_rename_native_namespace_profile_unsupported} =
             ElixirRename.plan(
               fixture.context,
               unknown,
               request(files, "old.ex", "OldName", "NewName"),
               []
             )

    assert contents(fixture, files) == files
  end

  test "same alias spelling is not a global identity when a function rebinds it", fixture do
    files = %{
      "left.ex" => "defmodule LeftSide do\n  def value(), do: 1\nend\n",
      "right.ex" => "defmodule RightSide do\n  def value(), do: 2\nend\n",
      "caller.ex" =>
        "defmodule ScopedCaller do\n  alias LeftSide, as: M\n  def first(), do: M.value()\n  def second() do\n    alias RightSide, as: M\n    M.value()\n  end\n  def third(), do: M.value()\nend\n"
    }

    left = token(files, "left.ex", "LeftSide")
    right = token(files, "right.ex", "RightSide")

    left_members = [
      left,
      token(files, "caller.ex", "LeftSide"),
      token(files, "caller.ex", "M.value", 0, 1),
      token(files, "caller.ex", "M.value", 2, 1)
    ]

    right_members = [
      right,
      token(files, "caller.ex", "RightSide"),
      token(files, "caller.ex", "M.value", 1, 1)
    ]

    caller = token(files, "caller.ex", "ScopedCaller")
    left_value = token(files, "left.ex", "value", 0, 5)
    right_value = token(files, "right.ex", "value", 0, 5)

    groups = [
      %{definition: left, members: left_members, references: left_members},
      %{definition: right, members: right_members, references: right_members},
      %{definition: caller, members: [caller], references: [caller]},
      %{
        definition: left_value,
        members: [
          left_value,
          token(files, "caller.ex", "value", 0, 5),
          token(files, "caller.ex", "value", 2, 5)
        ],
        references: [left_value]
      },
      %{
        definition: right_value,
        members: [right_value, token(files, "caller.ex", "value", 1, 5)],
        references: [right_value]
      }
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{occurrences: 2}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "left.ex", "LeftSide", "RenamedSide"),
               []
             )

    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
    rendered = Enum.find(plans, &(&1.path == "caller.ex")).content
    assert rendered =~ "alias RenamedSide, as: M"
    assert rendered =~ "alias RightSide, as: M"
    assert [_, _, _] = :binary.matches(rendered, "M.value()")
    refute Enum.any?(plans, &(&1.path == "right.ex"))
    assert contents(fixture, files) == files
  end

  test "an unrelated arity remains available at the destination name", fixture do
    {files, _groups} = function_project()

    files =
      Map.update!(
        files,
        "math.ex",
        &String.replace(&1, "  def local", "  def multiply(a, b, c), do: a + b + c\n  def local")
      )

    install(fixture, files)
    server = provider(fixture, files, function_groups(files))

    assert {:ok, edit, %{occurrences: 11}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})

    assert Enum.find(plans, &(&1.path == "math.ex")).content =~
             "def multiply(a, b, c), do: a + b + c"

    assert contents(fixture, files) == files
  end

  test "compiler-owned destinations reject remote-only callers and default-generated arities",
       fixture do
    for {parameters, arguments, body, owned} <- [
          {"", "", "1", [0]},
          {"value", "1", "value", [1]},
          {"left, right \\\\ 0", "1, 2", "{left, right}", [1]},
          {"left \\\\ 0, right \\\\ 0", "1, 2", "{left, right}", [0, 1]}
        ] do
      arity = if arguments == "", do: 0, else: length(String.split(arguments, ", "))
      {files, groups} = compiler_destination_project(parameters, arguments, body, arity)
      install(fixture, files)
      server = provider(fixture, files, groups)

      assert {:error,
              {:elixir_rename_compiler_owned_destination, %{name: "module_info", arities: ^owned}}} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "origin.ex", "old", "module_info", 0, 3),
                 []
               )

      assert GenServer.call(server, :notifications) == []
      assert contents(fixture, files) == files
    end
  end

  test "module_info with a non-compiler-owned arity renders a complete immutable preview",
       fixture do
    {files, groups} = compiler_destination_project("left, right", "1, 2", "{left, right}", 2)
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit,
            %{
              occurrences: 3,
              symbol: %{
                arities: [2],
                native_caller_scopes: [],
                caller_binding_profile: :no_unqualified_callers
              }
            }} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old", "module_info", 0, 3),
               []
             )

    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})

    assert Map.new(plans, &{&1.path, &1.content}) ==
             Map.new(files, fn {path, source} ->
               {path, String.replace(source, "old", "module_info")}
             end)

    assert GenServer.call(server, :notifications) == []
    assert contents(fixture, files) == files
  end

  test "module-scope runtime captures reject incomplete caller proofs without crashing",
       fixture do
    files = %{
      "origin.ex" => "defmodule CaptureOrigin do\n  def old(value), do: value\nend\n",
      "caller.ex" => """
      defmodule CaptureCaller do
        import CaptureOrigin, only: [old: 1]
        def preceding(), do: :ok
        @captured &old/1
      end
      """
    }

    definition = token(files, "origin.ex", "old", 0, 3)
    capture = token(files, "caller.ex", "old/1", 0, 3)
    module = token(files, "origin.ex", "CaptureOrigin")
    imported = token(files, "caller.ex", "CaptureOrigin")

    groups = [
      %{
        definition: definition,
        members: [definition, capture],
        references: [definition, capture]
      },
      %{definition: module, members: [module, imported], references: [module, imported]}
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, :elixir_rename_native_caller_bindings_incomplete} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old", "fresh", 0, 3),
               []
             )

    assert contents(fixture, files) == files
  end

  test "malformed module-scope function metadata returns a structured native proof error",
       fixture do
    uri = uri(fixture.root, "caller.ex")
    call = %{name: "old", kind: :call, arity: 1, code_position: %{line: 4, column: 14}}

    environment = %{
      "location" => %{"uri" => uri, "line" => 4, "column" => 14},
      "context" => %{"module" => "Elixir.CaptureCaller", "function" => nil},
      "imports" => [%{"module" => "CaptureOrigin", "function" => "old/1"}],
      "variables" => [],
      "definitions" => %{"functions_defined" => ["CaptureCaller.preceding/0"]}
    }

    for function <- [nil, %{}] do
      assert {:error, :elixir_rename_native_caller_bindings_incomplete} =
               Bindings.check(
                 environment,
                 uri,
                 call,
                 "CaptureOrigin",
                 "CaptureCaller",
                 function,
                 "fresh",
                 [1]
               )
    end
  end

  test "spec function heads rename without changing types, argument variables or runtime capture checks",
       fixture do
    {files, groups} = spec_function_project()
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{occurrences: 4, symbol: %{native_caller_scopes: proofs}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old(value), do:", "fresh", 0, 3),
               []
             )

    assert [%{context: %{module: "SpecOrigin", function: "local/0"}}] = proofs
    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})

    assert Map.new(plans, &{&1.path, &1.content}) == %{
             "origin.ex" =>
               String.replace(
                 files["origin.ex"],
                 ["@spec old(", "def old(", "&old/1"],
                 fn
                   "@spec old(" -> "@spec fresh("
                   "def old(" -> "def fresh("
                   "&old/1" -> "&fresh/1"
                 end
               ),
             "consumer.ex" => String.replace(files["consumer.ex"], "old(1)", "fresh(1)")
           }

    assert {:error,
            {:elixir_rename_destination_native_binding, %{path: "origin.ex"},
             [%{module: "Kernel", name: "length", arity: 1} | _]}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old(value), do:", "length", 0, 3),
               []
             )

    assert GenServer.call(server, :notifications) == []
    assert contents(fixture, files) == files
  end

  test "native whole-spec ranges identify only the authored signature head, not its type calls" do
    content = """
    defmodule SpecRange do
      @spec old(integer(), integer()) :: integer()
      def old(x, y), do: x + y
    end
    """

    {:ok, source} = Source.parse(%{path: "spec_range.ex", content: content})
    line = content |> String.split("\n") |> Enum.at(1)

    whole = %{
      "start" => %{"line" => 1, "character" => 2},
      "end" => %{"line" => 1, "character" => String.length(line)}
    }

    assert {:ok, %{name: "old", arity: 2, call_form: :spec_head}} =
             Source.anchored(source, whole)

    type = %{
      "start" => %{"line" => 1, "character" => 12},
      "end" => %{"line" => 1, "character" => 19}
    }

    assert {:ok, %{name: "integer", call_form: :local}} = Source.anchored(source, type)
    truncated = put_in(whole, ["end", "character"], 8)
    assert {:error, _reason} = Source.anchored(source, truncated)
  end

  test "native self-resolving specs require an independently proved authored implementation",
       fixture do
    {files, groups} = spec_function_project()
    install(fixture, files)
    server = provider(fixture, files, groups, mode: :spec_self_definition)
    selection = request(files, "origin.ex", "old(fresh", "fresh", 0, 3)
    assert {:ok, edit, _metadata} = ElixirRename.plan(fixture.context, server, selection, [])
    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
    rendered = Map.new(plans, &{&1.path, &1.content})
    assert rendered["origin.ex"] =~ "@spec fresh(fresh :: old(integer())) :: old(integer())"
    assert rendered["origin.ex"] =~ "def fresh(value)"
    assert rendered["origin.ex"] =~ "&fresh/1"
    assert rendered["consumer.ex"] =~ "fresh(1)"
    assert contents(fixture, files) == files

    for options <- [
          [mode: :spec_definition_cycle],
          [mode: :spec_self_definition, server_info: %{"name" => "Unaudited", "version" => "1"}]
        ] do
      unproved = provider(fixture, files, groups, options)

      assert {:error, {:elixir_rename_unproved_signature_implementation, _signature}} =
               ElixirRename.plan(fixture.context, unproved, selection, [])

      assert contents(fixture, files) == files
    end
  end

  test "a spec type expression cannot borrow the function-head exemption from native identity",
       fixture do
    {files, [function, type | rest]} = spec_function_project()
    [type_head | type_references] = type.members

    groups = [
      %{
        function
        | members: function.members ++ type_references,
          references: function.references ++ type_references
      },
      %{type | members: [type_head], references: [type_head]}
      | rest
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, :elixir_rename_native_caller_bindings_incomplete} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old(value), do:", "fresh", 0, 3),
               []
             )

    assert contents(fixture, files) == files
  end

  test "an import rename cannot capture an existing destination call merely because the old export has no callers",
       fixture do
    files = %{
      "origin.ex" => "defmodule Origin do\n  def old(), do: 1\nend\n",
      "other.ex" => "defmodule OtherDestination do\n  def fresh(), do: 2\nend\n",
      "caller.ex" =>
        "defmodule ExistingCaller do\n  import Origin, only: [old: 0]\n  import OtherDestination, only: [fresh: 0]\n  def run(), do: fresh()\nend\n"
    }

    origin = token(files, "origin.ex", "Origin")
    definition = token(files, "origin.ex", "old", 0, 3)
    other = token(files, "other.ex", "OtherDestination")
    fresh = token(files, "other.ex", "fresh", 0, 5)
    caller = token(files, "caller.ex", "fresh()", 0, 5)

    groups = [
      %{definition: definition, members: [definition], references: [definition]},
      %{
        definition: origin,
        members: [origin, token(files, "caller.ex", "Origin")],
        references: [origin]
      },
      %{
        definition: other,
        members: [other, token(files, "caller.ex", "OtherDestination")],
        references: [other]
      },
      %{definition: fresh, members: [fresh, caller], references: [fresh, caller]}
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_existing_destination_capture, %{path: "caller.ex"}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old", "fresh", 0, 3),
               []
             )

    assert contents(fixture, files) == files
  end

  test "bare zero-arity calls respect native visible variables whereas parentheses force function calls",
       fixture do
    for {syntax, expected} <- [{"old", :capture}, {"old()", :ok}, {"old(), old", :capture}] do
      files = %{
        "zero.ex" =>
          "defmodule Zero do\n  def old(), do: 1\n  def run(input), do: {#{syntax}, input}\nend\n"
      }

      definition = token(files, "zero.ex", "old", 0, 3)

      calls =
        for index <- 1..length(:binary.matches(syntax, "old")),
            do: token(files, "zero.ex", "old", index, 3)

      inputs = Enum.map(0..1, &token(files, "zero.ex", "input", &1))

      groups = [
        %{
          definition: definition,
          members: [definition | calls],
          references: [definition | calls]
        },
        %{definition: hd(inputs), members: inputs, references: inputs}
      ]

      install(fixture, files)
      server = provider(fixture, files, groups, visible_variables: ["input"])

      result =
        ElixirRename.plan(
          fixture.context,
          server,
          request(files, "zero.ex", "old", "input", 0, 3),
          []
        )

      case expected do
        :capture ->
          assert {:error, {:elixir_rename_destination_native_binding, _, [%{kind: "variable"}]}} =
                   result

        :ok ->
          assert {:ok, edit, %{occurrences: 2}} = result
          assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
          assert plan.content =~ "def input()"
          assert plan.content =~ "{input(), input}"
      end

      assert contents(fixture, files) == files
    end
  end

  test "bare-call binding checks retain positions across an intervening assignment", fixture do
    files = %{
      "positions.ex" => """
      defmodule Positions do
        def old(), do: 1
        def run() do
          first = old
          input = 9
          {first, old, input}
        end
      end
      """
    }

    old = Enum.map(0..2, &token(files, "positions.ex", "old", &1, 3))

    groups =
      [%{definition: hd(old), members: old, references: old}] ++
        Enum.map(["first", "input"], fn name ->
          members = Enum.map(0..1, &token(files, "positions.ex", name, &1))
          %{definition: hd(members), members: members, references: members}
        end)

    install(fixture, files)

    server =
      provider(fixture, files, groups,
        visible_variables: fn position -> if position.line >= 6, do: ["input"], else: [] end
      )

    assert {:error, {:elixir_rename_destination_native_binding, _, [%{kind: "variable"}]}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "positions.ex", "old", "input", 0, 3),
               []
             )

    assert contents(fixture, files) == files
  end

  test "different case clauses have independent destination bindings", fixture do
    files = %{
      "clauses.ex" =>
        "defmodule Clauses do\n  def run(subject) do\n    case subject do\n      {:left, value} -> value\n      {:right, input} -> input\n    end\n  end\nend\n"
    }

    groups =
      Enum.map(["subject", "value", "input"], fn name ->
        members = Enum.map(0..1, &token(files, "clauses.ex", name, &1))
        %{definition: hd(members), members: members, references: members}
      end)

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{occurrences: 2}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "clauses.ex", "value", "input"),
               []
             )

    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
    assert plan.content =~ "{:left, input} -> input"
    assert plan.content =~ "{:right, input} -> input"
    assert contents(fixture, files) == files
  end

  test "Unicode variables and preceding astral text preserve exact UTF16 and literal ranges",
       fixture do
    files = %{
      "unicode.ex" =>
        "defmodule UnicodeVars do\r\n  def run(café), do: {\"😀\", café, \"café\", café}\r\nend\r\n"
    }

    members = Enum.map([0, 1, 3], &token(files, "unicode.ex", "café", &1))
    install(fixture, files)

    server =
      provider(fixture, files, [%{definition: hd(members), members: members, references: members}])

    assert {:ok, edit, %{occurrences: 3}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "unicode.ex", "café", "résumé"),
               []
             )

    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})

    assert plan.content ==
             "defmodule UnicodeVars do\r\n  def run(résumé), do: {\"😀\", résumé, \"café\", résumé}\r\nend\r\n"

    assert contents(fixture, files) == files
  end

  test "function and variable destination captures reject before writing", fixture do
    {files, _groups} = function_project()

    files =
      Map.update!(
        files,
        "user.ex",
        &String.replace(
          &1,
          "  def remote",
          "  def multiply(_x, _y), do: :captured\r\n  def remote"
        )
      )

    # Rebuild location evidence after changing authored coordinates.
    groups = function_groups(files)
    install(fixture, files)
    server = provider(fixture, files, groups)
    before = contents(fixture, files)

    assert {:error, {:elixir_rename_destination_capture, _}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert before == contents(fixture, files)

    {variable_files, variable_groups} = variable_project()
    install(fixture, variable_files)
    variable_server = provider(fixture, variable_files, variable_groups)

    assert {:error, {:elixir_rename_destination_capture, _}} =
             ElixirRename.plan(
               fixture.context,
               variable_server,
               request(variable_files, "vars.ex", "value", "first"),
               []
             )
  end

  test "an overlapping local alias destination is rejected before writing", fixture do
    {module_files, _module_groups} = module_project()

    module_files =
      Map.update!(
        module_files,
        "uses.ex",
        &String.replace(&1, "  alias OldName\n", "  alias Other, as: NewName\n  alias OldName\n")
      )

    module_files = Map.put(module_files, "other.ex", "defmodule Other do\nend\n")
    install(fixture, module_files)
    other = token(module_files, "other.ex", "Other")
    imported = token(module_files, "uses.ex", "Other")

    groups =
      module_groups(module_files) ++
        [%{definition: other, members: [other, imported], references: [other, imported]}]

    module_server = provider(fixture, module_files, groups)

    assert {:error, :elixir_rename_destination_alias_capture} =
             ElixirRename.plan(
               fixture.context,
               module_server,
               request(module_files, "old.ex", "OldName", "NewName"),
               []
             )
  end

  test "a same-module overlapping destination and implicit Kernel capture are rejected",
       fixture do
    {files, _groups} = function_project()

    files =
      Map.update!(
        files,
        "math.ex",
        &String.replace(&1, "  def local", "  def multiply(_x), do: :occupied\n  def local")
      )

    install(fixture, files)
    server = provider(fixture, files, function_groups(files))

    assert {:error, {:elixir_rename_destination_collision, _}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert {:error, {:elixir_rename_destination_native_binding, _, [%{module: "Kernel"} | _]}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "length"), [])
  end

  test "malformed, missing, out-of-root and unauthored native evidence cannot produce a preview",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    request = function_request(files, "multiply")
    before = contents(fixture, files)

    for mode <- [
          :missing_definition,
          :malformed_definition,
          :missing_references,
          :out_of_root_reference,
          :literal_reference
        ] do
      server = provider(fixture, files, groups, mode: mode)
      assert {:error, _reason} = ElixirRename.plan(fixture.context, server, request, [])
      assert contents(fixture, files) == before
    end
  end

  test "a provider omitting a real candidate cannot hide behind nonempty references", fixture do
    {files, groups} = function_project()

    groups =
      List.update_at(groups, 0, fn group ->
        %{
          group
          | members:
              Enum.reject(group.members, &(&1 == token(files, "user.ex", "product(x, 3)", 0, 7)))
        }
      end)

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_unresolved_candidate, %{path: "user.ex"}}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])
  end

  test "complete inventory, semantic requests, edit count and stale caller inputs are bounded",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups)
    request = function_request(files, "multiply")

    assert {:error, :elixir_rename_inventory_limit} =
             ElixirRename.plan(fixture.context, server, request, rename_max_files: 1)

    assert {:error, :elixir_rename_inventory_bytes} =
             ElixirRename.plan(fixture.context, server, request, rename_max_bytes: 1)

    assert {:error, :elixir_rename_candidate_limit} =
             ElixirRename.plan(fixture.context, server, request, rename_max_candidates: 1)

    assert {:error, {:elixir_rename_stale_snapshot, "math.ex", _, _}} =
             ElixirRename.plan(
               fixture.context,
               server,
               Map.put(request, :snapshot, String.duplicate("0", 64)),
               []
             )

    assert {:error, :elixir_rename_invalid_name} =
             ElixirRename.plan(fixture.context, server, %{request | new_name: "bad.name"}, [])

    assert contents(fixture, files) == files
  end

  test "an input changing during native resolution fails rather than planning against stale checked source",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups, mode: :change_source)

    assert {:error, {:elixir_rename_source_changed, "math.ex"}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert File.read!(Path.join(fixture.root, "math.ex")) ==
             files["math.ex"] <> "# external change\n"

    assert File.read!(Path.join(fixture.root, "user.ex")) == files["user.ex"]
  end

  test "quoted target identity is rejected explicitly", fixture do
    {files, groups} = function_project()

    files =
      Map.put(
        files,
        "generated.ex",
        "defmodule Generated do\n  def code(), do: quote(do: product(1))\nend\n"
      )

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_semantic_uncertainty, %{reason: :quoted_code}}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "dynamic dispatch is an explicit completeness failure", fixture do
    {files, groups} = function_project()

    files =
      Map.put(
        files,
        "dynamic.ex",
        "defmodule Dynamic do\n  def call(module, name, args), do: apply(module, name, args)\nend\n"
      )

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_semantic_uncertainty, %{reason: :dynamic_dispatch}}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "qualified, aliased and imported runtime API calls cannot hide dynamic symbol references",
       fixture do
    for {setup, expression, reason} <- [
          {"", "Elixir.Function.capture(RenameMath, :product, 1)", :dynamic_dispatch},
          {"", ":erpc.call(node(), RenameMath, :product, [1])", :dynamic_dispatch},
          {"alias Elixir, as: E", "E.Function.capture(RenameMath, :product, 1)",
           :dynamic_dispatch},
          {"alias Function, as: F", "F.capture(RenameMath, :product, 1)", :dynamic_dispatch},
          {"alias Module, as: M", "M.concat([RenameMath])", :dynamic_module},
          {"import Function, only: [capture: 3]", "capture(RenameMath, :product, 1)",
           :dynamic_dispatch},
          {"import Module, only: [concat: 1]", "concat([RenameMath])", :dynamic_module},
          {"", "Elixir.Code.eval_quoted(quote do: :ok)", :dynamic_module}
        ] do
      {files, groups} = function_project()

      files =
        Map.put(
          files,
          "runtime.ex",
          "defmodule RuntimeRefs do\n #{setup}\n def run(), do: #{expression}\nend\n"
        )

      install(fixture, files)
      server = provider(fixture, files, groups)

      assert {:error, {:elixir_rename_semantic_uncertainty, %{reason: ^reason}}} =
               ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

      assert contents(fixture, files) == files
    end
  end

  test "an unrelated anonymous-function destination binding does not capture an outer variable",
       fixture do
    {files, _groups} = variable_project()

    files =
      Map.update!(
        files,
        "vars.ex",
        &String.replace(&1, "fn value -> value + 10", "fn input -> input + 10")
      )

    indexes = [{"value", [0, 1, 3]}, {"value", [2, 4, 5, 6, 7]}, {"input", [0, 1]}]

    groups =
      Enum.map(indexes, fn {name, indexes} ->
        members = Enum.map(indexes, &token(files, "vars.ex", name, &1))
        %{definition: hd(members), members: members, references: members}
      end)

    groups = groups ++ variable_support_groups(files)
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{occurrences: 3}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "vars.ex", "value", "input"),
               []
             )

    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
    assert plan.content =~ "def run(input)"
    assert plan.content =~ "value = input + 1"
    assert plan.content =~ "fn input -> input + 10 end"
    assert contents(fixture, files) == files
  end

  test "a macro introducing an imported destination cannot hide behind an ordinary old call",
       fixture do
    files = %{
      "origin.ex" => "defmodule Origin do\n  def old(), do: 1\nend\n",
      "macro.ex" =>
        "defmodule ImportMacro do\n  defmacro bring() do\n    quote do: import OtherDestination, only: [fresh: 0]\n  end\nend\n",
      "other.ex" => "defmodule OtherDestination do\n  def fresh(), do: 2\nend\n",
      "caller.ex" =>
        "defmodule MacroCaller do\n  import Origin, only: [old: 0]\n  import ImportMacro, only: [bring: 0]\n  def run() do\n    bring()\n    old()\n  end\nend\n"
    }

    old = token(files, "origin.ex", "old", 0, 3)
    origin = token(files, "origin.ex", "Origin")
    macro = token(files, "macro.ex", "bring", 0, 5)
    macro_module = token(files, "macro.ex", "ImportMacro")

    groups = [
      %{
        definition: old,
        members: [old, token(files, "caller.ex", "old()", 0, 3)],
        references: [old]
      },
      %{
        definition: origin,
        members: [origin, token(files, "caller.ex", "Origin")],
        references: [origin]
      },
      %{
        definition: macro,
        members: [macro, token(files, "caller.ex", "bring()", 0, 5)],
        references: [macro]
      },
      %{
        definition: macro_module,
        members: [macro_module, token(files, "caller.ex", "ImportMacro")],
        references: [macro_module]
      }
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error,
            {:elixir_rename_unproven_caller_scope, _,
             {:elixir_rename_opaque_variable_callee, %{name: "bring"}}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old", "fresh", 0, 3),
               []
             )

    assert contents(fixture, files) == files
  end

  test "generated destination capture is rejected even when the new name has no authored caller token",
       fixture do
    files = %{
      "macro.ex" =>
        "defmodule CaptureMacro do\n  defmacro introduce() do\n    quote do: var!(input) = 42\n  end\nend\n",
      "vars.ex" =>
        "defmodule CaptureUser do\n  import CaptureMacro, only: [introduce: 0]\n  def run(value) do\n    introduce()\n    value\n  end\nend\n"
    }

    values = Enum.map(0..1, &token(files, "vars.ex", "value", &1))
    macro = token(files, "macro.ex", "introduce", 0, 9)
    call = token(files, "vars.ex", "introduce()", 0, 9)
    macro_module = token(files, "macro.ex", "CaptureMacro")
    imported_module = token(files, "vars.ex", "CaptureMacro")

    groups = [
      %{definition: hd(values), members: values, references: values},
      %{definition: macro, members: [macro, call], references: [macro, call]},
      %{
        definition: macro_module,
        members: [macro_module, imported_module],
        references: [macro_module, imported_module]
      }
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_opaque_variable_callee, %{name: "introduce"}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "vars.ex", "value", "input"),
               []
             )

    assert contents(fixture, files) == files
  end

  test "external function kind is read from supported native metadata rather than an outside-root SDK read",
       fixture do
    {files, groups, call} = sdk_variable_project()
    install(fixture, files)

    hover =
      "```elixir\nRemoteOps.map(enumerable, fun)\n```\n\n*function* \n\n### Documentation\nexternal function\n"

    server =
      provider(fixture, files, groups,
        server_info: %{"name" => "ElixirLS", "version" => "0.31.1"},
        hovers: [%{location: call, markdown: hover}]
      )

    assert {:ok, edit,
            %{
              occurrences: 3,
              native_hover_requests: 1,
              native_callable_kinds: %{verified_external_calls: 1}
            }} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "vars.ex", "value", "input"),
               []
             )

    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
    assert plan.content =~ "def run(input)"
    assert plan.content =~ "Ops.map([input], fn item -> {item, input} end)"
    assert contents(fixture, files) == files
  end

  test "hover documentation cannot spoof callable kind and unknown provider formats fail closed",
       fixture do
    {files, groups, call} = sdk_variable_project()
    install(fixture, files)
    counterfeit = "```elixir\nRemoteOps.map(enumerable, fun)\n```\n\n*function* \n"

    for hover <- [
          "### Documentation\n" <> counterfeit,
          "```elixir\nRemoteOps.map(enumerable, fun)\n```\n\n*macro* \n\n### Documentation\n" <>
            counterfeit,
          "```elixir\nRemoteOps.other(enumerable, fun)\n```\n\n*function* \n"
        ] do
      server =
        provider(fixture, files, groups,
          server_info: %{"name" => "ElixirLS", "version" => "0.31.1"},
          hovers: [%{location: call, markdown: hover}]
        )

      assert {:error, _reason} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "vars.ex", "value", "input"),
                 []
               )
    end

    server =
      provider(fixture, files, groups,
        server_info: %{"name" => "Unknown", "version" => "0.31.1"},
        hovers: [%{location: call, markdown: counterfeit}]
      )

    assert {:error, {:elixir_rename_opaque_variable_callee, _}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "vars.ex", "value", "input"),
               []
             )

    assert contents(fixture, files) == files
  end

  test "server document versions changing during semantic reads invalidate the preview",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups, mode: :change_versions)

    assert {:error, :elixir_rename_server_documents_changed} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "native stale same-length receiver text is replaced by the actual checked source before identity queries",
       fixture do
    files = %{
      "alpha.ex" => "defmodule Alpha do\n  def foo(), do: 1\nend\n",
      "bravo.ex" => "defmodule Bravo do\n  def foo(), do: 2\nend\n",
      "caller.ex" => "defmodule Caller do\n  def run(), do: Bravo.foo()\nend\n"
    }

    old_buffers = Map.update!(files, "caller.ex", &String.replace(&1, "Bravo", "Alpha"))
    alpha = token(files, "alpha.ex", "foo", 0, 3)
    bravo = token(files, "bravo.ex", "foo", 0, 3)
    call = token(files, "caller.ex", "foo", 0, 3)
    alpha_module = token(files, "alpha.ex", "Alpha")
    bravo_module = token(files, "bravo.ex", "Bravo")
    receiver = token(files, "caller.ex", "Bravo")

    groups = [
      %{definition: alpha, members: [alpha, call], references: [alpha, call]},
      %{definition: bravo, members: [bravo], references: [bravo]},
      %{
        definition: alpha_module,
        members: [alpha_module, receiver],
        references: [alpha_module, receiver]
      },
      %{definition: bravo_module, members: [bravo_module], references: [bravo_module]}
    ]

    install(fixture, files)
    server = provider(fixture, files, groups, native_files: old_buffers, mode: :stale_receiver)

    assert {:ok, edit, metadata} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "alpha.ex", "foo", "bar", 0, 3),
               []
             )

    assert metadata.native_inputs.synchronized == [
             %{
               path: "caller.ex",
               snapshot: Files.snapshot(files["caller.ex"]),
               version: 8,
               operation: :change
             }
           ]

    assert [
             %{
               reason: :attested_input_now_resolves_differently,
               current_definition: %{path: "bravo.ex"}
             }
           ] = metadata.native_stale_reference_exclusions

    assert [{"textDocument/didChange", %{"contentChanges" => [%{"text" => text}]}}] =
             GenServer.call(server, :notifications)

    assert text == files["caller.ex"]
    assert {:ok, [plan]} = TextEdits.plan(fixture.context, edit, %{})
    assert plan.path == "alpha.ex"
    assert plan.content =~ "def bar()"
    # A preview leaves compiler trace refs stale; an immediate apply planning
    # pass must use the same attested current identities without another sync.
    assert {:ok, ^edit, second_metadata} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "alpha.ex", "foo", "bar", 0, 3),
               []
             )

    assert second_metadata.native_inputs.synchronized == []
    assert [_] = second_metadata.native_stale_reference_exclusions
    assert contents(fixture, files) == files
  end

  test "unknown incremental fingerprints are repaired with full real input and initially closed files are opened",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    unknown = provider(fixture, files, groups, unknown_snapshots: ["user.ex"])

    assert {:ok, edit, %{native_inputs: %{synchronized: [%{path: "user.ex", version: 8}]}}} =
             ElixirRename.plan(fixture.context, unknown, function_request(files, "multiply"), [])

    assert Enum.find(
             edit["documentChanges"],
             &String.ends_with?(&1["textDocument"]["uri"], "/user.ex")
           )["textDocument"]["version"] == 8

    closed = provider(fixture, files, groups, closed: true)

    assert {:ok, edit, %{native_inputs: %{synchronized: synchronized}}} =
             ElixirRename.plan(fixture.context, closed, function_request(files, "multiply"), [])

    assert [_, _, _] = synchronized
    assert Enum.all?(synchronized, &(&1.operation == :open and &1.version == 1))
    assert Enum.all?(edit["documentChanges"], &(&1["textDocument"]["version"] == 1))
    assert contents(fixture, files) == files
  end

  test "missing ownership/fingerprints, refused sync, and same-version buffer replacement never publish",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    request = function_request(files, "multiply")
    untracked = provider(fixture, files, groups, untracked: true)

    assert {:error, {:elixir_rename_untracked_native_document, _path}} =
             ElixirRename.plan(fixture.context, untracked, request, [])

    assert GenServer.call(untracked, :notifications) == []
    refused = provider(fixture, files, groups, unknown_snapshots: ["user.ex"], mode: :sync_denied)

    assert {:error, :native_sync_denied} =
             ElixirRename.plan(fixture.context, refused, request, [])

    changed = provider(fixture, files, groups, mode: :change_fingerprints)

    assert {:error, {:elixir_rename_server_source_changed, _uri}} =
             ElixirRename.plan(fixture.context, changed, request, [])

    foreign = provider(fixture, files, groups, closed: true)
    wrong_owner = %{fixture.context | session_id: "another-session"}
    assert {:error, :wrong_workspace} = ElixirRename.plan(wrong_owner, foreign, request, [])
    assert GenServer.call(foreign, :notifications) == []
    assert contents(fixture, files) == files
  end

  test "a current source buffer cannot rescue contradictory native receiver or import identity",
       fixture do
    files = %{
      "alpha.ex" => "defmodule Alpha do\n  def foo(), do: 1\nend\n",
      "bravo.ex" => "defmodule Bravo do\n  def foo(), do: 2\nend\n",
      "caller.ex" => "defmodule Caller do\n  def run(), do: Bravo.foo()\nend\n"
    }

    alpha = token(files, "alpha.ex", "foo", 0, 3)
    call = token(files, "caller.ex", "foo", 0, 3)
    alpha_module = token(files, "alpha.ex", "Alpha")

    groups = [
      %{definition: alpha, members: [alpha, call], references: [alpha, call]},
      %{
        definition: alpha_module,
        members: [alpha_module, token(files, "caller.ex", "Bravo")],
        references: [alpha_module]
      }
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_native_module_identity_mismatch, %{name: "Bravo"}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "alpha.ex", "foo", "bar", 0, 3),
               []
             )

    assert GenServer.call(server, :notifications) == []
    assert contents(fixture, files) == files
  end

  test "a fresh import qualifier cannot be assigned the stale function owner's identity",
       fixture do
    files = %{
      "alpha.ex" => "defmodule Alpha do\n  def foo(), do: 1\nend\n",
      "bravo.ex" => "defmodule Bravo do\n  def foo(), do: 2\nend\n",
      "caller.ex" =>
        "defmodule Caller do\n  import Bravo, only: [foo: 0]\n  def run(), do: foo()\nend\n"
    }

    alpha = token(files, "alpha.ex", "foo", 0, 3)
    bravo = token(files, "bravo.ex", "Bravo")

    groups = [
      %{
        definition: alpha,
        members: [alpha, token(files, "caller.ex", "foo()", 0, 3)],
        references: [alpha]
      },
      %{
        definition: bravo,
        members: [bravo, token(files, "caller.ex", "Bravo")],
        references: [bravo]
      }
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_native_import_identity_mismatch, %{path: "caller.ex"}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "alpha.ex", "foo", "bar", 0, 3),
               []
             )

    assert GenServer.call(server, :notifications) == []
    assert contents(fixture, files) == files
  end

  test "aggregate native locations and virtual-document evidence are bounded before publication",
       fixture do
    {files, groups} = function_project()
    install(fixture, files)
    flood = provider(fixture, files, groups, mode: :location_flood)

    assert {:error, :elixir_rename_native_location_limit} =
             ElixirRename.plan(fixture.context, flood, function_request(files, "multiply"), [])

    virtual = provider(fixture, files, groups, mode: :virtual_definition)

    assert {:error, :elixir_rename_invalid_provider_location} =
             ElixirRename.plan(fixture.context, virtual, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "unclassified native environments cannot claim destination absence", fixture do
    {files, groups} = function_project()
    install(fixture, files)
    server = provider(fixture, files, groups, mode: :malformed_completion)

    assert {:error, :elixir_rename_native_caller_bindings_incomplete} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    unknown = provider(fixture, files, groups, server_info: nil)

    assert {:error, :elixir_rename_native_caller_binding_profile_unsupported} =
             ElixirRename.plan(fixture.context, unknown, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "opaque compiler scopes are reported rather than assuming source-visible definitions are all definitions",
       fixture do
    {files, _groups} = function_project()

    files =
      Map.update!(
        files,
        "math.ex",
        &String.replace(&1, "  @moduledoc", "  use UnknownGenerator\n  @moduledoc")
      )

    install(fixture, files)
    server = provider(fixture, files, function_groups(files))

    assert {:error, {:elixir_rename_semantic_uncertainty, %{reason: :opaque_use}}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "standard compiler callback attributes cannot retain a removed function name", fixture do
    for {attribute, arguments} <- [
          {"on_definition", ~w(env kind name args guards body)},
          {"after_verify", ["module"]}
        ] do
      params = Enum.map_join(arguments, ", ", &("_" <> &1))
      values = Enum.map_join(arguments, ", ", fn _ -> "nil" end)

      files = %{
        "hook.ex" =>
          "defmodule Hook do\n def old(#{params}), do: :ok\n def direct(), do: old(#{values})\nend\n",
        "consumer.ex" =>
          "defmodule CallbackConsumer do\n @#{attribute} {Hook, :old}\n def value(), do: 1\nend\n"
      }

      members = Enum.map(0..1, &token(files, "hook.ex", "old", &1, 3))
      install(fixture, files)

      server =
        provider(fixture, files, [
          %{definition: hd(members), members: members, references: members}
        ])

      assert {:error, {:elixir_rename_semantic_uncertainty, %{reason: :compiler_attribute}}} =
               ElixirRename.plan(
                 fixture.context,
                 server,
                 request(files, "hook.ex", "old", "fresh", 0, 3),
                 []
               )

      assert contents(fixture, files) == files
    end
  end

  test "source parsing is not expansion and malformed inventory never partially succeeds",
       fixture do
    {files, groups} = function_project()
    sentinel = Path.join(fixture.root, "must-not-exist")

    files =
      Map.put(
        files,
        "unsafe.ex",
        "defmodule Unsafe do\n  File.write!(#{inspect(sentinel)}, \"evaluated\")\nend\n"
      )

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, _edit, _metadata} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    refute File.exists?(sentinel)
    File.write!(Path.join(fixture.root, "broken.ex"), "defmodule Broken do\n")

    assert {:error, {:elixir_rename_parse_error, "broken.ex", _}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])
  end

  test "an unrelated imported destination is capture, not a spelling-safe rename", fixture do
    {files, _groups} = function_project()

    files =
      files
      |> Map.update!(
        "other.ex",
        &String.replace(&1, "  def own", "  def multiply(x), do: x\n  def own")
      )
      |> Map.update!(
        "user.ex",
        &String.replace(
          &1,
          "  def remote",
          "  import RenameOther, only: [multiply: 1]\r\n  def remote"
        )
      )

    module = token(files, "other.ex", "RenameOther")
    imported = token(files, "user.ex", "RenameOther")

    groups =
      function_groups(files) ++
        [%{definition: module, members: [module, imported], references: [module, imported]}]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_destination_import_capture, _}} =
             ElixirRename.plan(fixture.context, server, function_request(files, "multiply"), [])

    assert contents(fixture, files) == files
  end

  test "a currently harmless destination exclusion cannot remove the renamed imported function",
       fixture do
    files = %{
      "origin.ex" => "defmodule ExcludedOrigin do\n def old(), do: 1\nend\n",
      "caller.ex" =>
        "defmodule ExcludedCaller do\n import ExcludedOrigin, except: [fresh: 0]\n def run(), do: old()\nend\n"
    }

    definition = token(files, "origin.ex", "old", 0, 3)
    call = token(files, "caller.ex", "old", 0, 3)
    module = token(files, "origin.ex", "ExcludedOrigin")
    imported = token(files, "caller.ex", "ExcludedOrigin")

    groups = [
      %{definition: definition, members: [definition, call], references: [definition, call]},
      %{definition: module, members: [module, imported], references: [module, imported]}
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, {:elixir_rename_destination_import_excluded, %{path: "caller.ex"}}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "old", "fresh", 0, 3),
               []
             )

    assert contents(fixture, files) == files
  end

  test "import except keys preserve their exclusions rather than becoming ordinary calls",
       fixture do
    files = %{
      "math.ex" => "defmodule MathExcept do\n  def product(x), do: x\nend\n",
      "uses.ex" =>
        "defmodule UsesExcept do\n  import MathExcept, except: [product: 1]\n  def run(), do: MathExcept.product(1)\nend\n"
    }

    definition = token(files, "math.ex", "product", 0, 7)
    call = token(files, "uses.ex", "product(1)", 0, 7)
    module = token(files, "math.ex", "MathExcept")
    imported = token(files, "uses.ex", "MathExcept", 0)

    groups = [
      %{definition: definition, members: [definition, call], references: [definition, call]},
      %{
        definition: module,
        members: [module, imported, token(files, "uses.ex", "MathExcept", 1)],
        references: [module, imported]
      }
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:ok, edit, %{occurrences: 3}} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "math.ex", "product", "multiply"),
               []
             )

    assert {:ok, plans} = TextEdits.plan(fixture.context, edit, %{})
    assert Enum.find(plans, &(&1.path == "uses.ex")).content =~ "except: [multiply: 1]"
    assert contents(fixture, files) == files
  end

  test "more than one thousand precise authored edits fail before publication", fixture do
    source =
      "defmodule Many do\n  def value(), do: 1\n  def run() do\n" <>
        String.duplicate("    value()\n", 1_000) <> "  end\nend\n"

    files = %{"many.ex" => source}
    members = Enum.map(0..1_000, &token(files, "many.ex", "value", &1))
    groups = [%{definition: hd(members), members: members, references: [hd(members)]}]
    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, :lsp_edit_limit} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "many.ex", "value", "answer"),
               []
             )

    assert contents(fixture, files) == files
  end

  test "more than thirty-two edited documents fail without narrowing the inventory", fixture do
    files =
      Map.new(1..33, fn number ->
        {"caller_#{number}.ex",
         "defmodule Caller#{number} do\n  def run(), do: Origin.value()\nend\n"}
      end)
      |> Map.put("origin.ex", "defmodule Origin do\n  def value(), do: 1\nend\n")

    definition = token(files, "origin.ex", "value")
    members = [definition | Enum.map(1..33, &token(files, "caller_#{&1}.ex", "value"))]
    module = token(files, "origin.ex", "Origin")
    receivers = Enum.map(1..33, &token(files, "caller_#{&1}.ex", "Origin"))

    groups = [
      %{definition: definition, members: members, references: members},
      %{definition: module, members: [module | receivers], references: [module | receivers]}
    ]

    install(fixture, files)
    server = provider(fixture, files, groups)

    assert {:error, :lsp_document_limit} =
             ElixirRename.plan(
               fixture.context,
               server,
               request(files, "origin.ex", "value", "answer"),
               []
             )

    assert contents(fixture, files) == files
  end

  defp function_project do
    files = %{
      "math.ex" =>
        "defmodule RenameMath do\n  @moduledoc \"product is literal documentation\"\n  def product(x, y \\\\ 2)\n  def product(0, _y), do: 0\n  def product(x, y), do: x * y\n  def product(a, b, c), do: a * b * c\n  def local(x), do: product(x)\nend\n",
      "user.ex" =>
        "defmodule RenameUser do\r\n  alias RenameMath, as: M\r\n  import RenameMath, only: [product: 1, product: 2, product: 3]\r\n  def remote(x), do: {\"😀 product\", M.product(x)}\r\n  def imported(x), do: product(x, 3)\r\n  def piped(x), do: x |> product()\r\n  def captures(), do: {&M.product/1, &product/2}\r\n  def unrelated(), do: M.product(1, 2, 3)\r\n  def literal(), do: \"😀 product\"\r\n  # product stays a comment\r\nend\r\n",
      "other.ex" =>
        "defmodule RenameOther do\n  def product(x), do: x\n  def own(), do: product(1)\nend\n"
    }

    {files, function_groups(files)}
  end

  defp function_groups(files) do
    header = token(files, "math.ex", "product(x, y", 0, 7)

    members = [
      header,
      token(files, "math.ex", "product(0", 0, 7),
      token(files, "math.ex", "product(x, y", 1, 7),
      token(files, "math.ex", "product(x)", 0, 7),
      token(files, "user.ex", "product(x)", 0, 7),
      token(files, "user.ex", "product(x, 3)", 0, 7),
      token(files, "user.ex", "product()", 0, 7),
      token(files, "user.ex", "product/1", 0, 7),
      token(files, "user.ex", "product/2", 0, 7)
    ]

    whole_head = token(files, "math.ex", "def product(x, y", 0, byte_size("def product(x, y"))
    math_module = token(files, "math.ex", "RenameMath")

    math_modules =
      [
        math_module,
        token(files, "user.ex", "RenameMath", 0),
        token(files, "user.ex", "RenameMath", 1)
      ] ++ Enum.map(0..2, &token(files, "user.ex", "M.product", &1, 1))

    other = token(files, "other.ex", "product(x)", 0, 7)

    [
      %{
        definition: whole_head,
        members: members,
        references: [whole_head | Enum.drop(members, 3)]
      },
      %{definition: math_module, members: math_modules, references: math_modules},
      %{
        definition: other,
        members: [other, token(files, "other.ex", "product(1)", 0, 7)],
        references: [other, token(files, "other.ex", "product(1)", 0, 7)]
      }
    ] ++
      [
        binding_group(files, "math.ex", "def local(x), do: product(x)", "x"),
        binding_group(files, "user.ex", "def remote(x), do: {\"😀 product\", M.product(x)}", "x"),
        binding_group(files, "user.ex", "def imported(x), do: product(x, 3)", "x"),
        binding_group(files, "user.ex", "def piped(x), do: x |> product()", "x")
      ]
  end

  defp compiler_destination_project(parameters, arguments, body, arity) do
    files = %{
      "origin.ex" => "defmodule CompilerOrigin do\n  def old(#{parameters}), do: #{body}\nend\n",
      "caller.ex" =>
        "defmodule CompilerCaller do\n  def run(), do: CompilerOrigin.old(#{arguments})\n  def captured(), do: &CompilerOrigin.old/#{arity}\nend\n"
    }

    definition = token(files, "origin.ex", "old", 0, 3)
    members = [definition | Enum.map(0..1, &token(files, "caller.ex", "old", &1, 3))]
    module = token(files, "origin.ex", "CompilerOrigin")
    receivers = Enum.map(0..1, &token(files, "caller.ex", "CompilerOrigin", &1))

    groups = [
      %{definition: definition, members: members, references: members},
      %{
        definition: module,
        members: [module | receivers],
        references: [module | receivers]
      }
    ]

    {files, groups}
  end

  defp spec_function_project do
    files = %{
      "origin.ex" => """
      defmodule SpecOrigin do
        def harmless(), do: 0
        @type old(value) :: value
        @spec old(fresh :: old(integer())) :: old(integer())
        def old(value), do: value
        def local(), do: &old/1
      end
      """,
      "consumer.ex" => """
      defmodule SpecConsumer do
        def run(), do: SpecOrigin.old(1)
      end
      """
    }

    definition = token(files, "origin.ex", "old(value), do:", 0, 3)

    members = [
      token(files, "origin.ex", "old(fresh", 0, 3),
      definition,
      token(files, "origin.ex", "old/1", 0, 3),
      token(files, "consumer.ex", "old(1)", 0, 3)
    ]

    type = token(files, "origin.ex", "old(value)", 0, 3)
    types = [type | Enum.map(0..1, &token(files, "origin.ex", "old(integer())", &1, 3))]
    argument = token(files, "origin.ex", "fresh")
    module = token(files, "origin.ex", "SpecOrigin")
    receiver = token(files, "consumer.ex", "SpecOrigin")

    groups = [
      %{definition: definition, members: members, references: members},
      %{definition: type, members: types, references: types},
      %{definition: argument, members: [argument], references: [argument]},
      %{definition: module, members: [module, receiver], references: [module, receiver]},
      binding_group(files, "origin.ex", "def old(value), do: value", "value")
    ]

    {files, groups}
  end

  defp variable_project do
    files = %{
      "vars.ex" =>
        "defmodule Vars do\n  def run(value) do\n    first = value\n    value = value + 1\n    nested = fn value -> value + 10 end\n    captured = fn -> value end\n    case first do\n      ^value -> value\n    end\n    {first, value, nested, captured}\n  end\nend\n"
    }

    bindings = [[0, 1, 3], [2, 6, 7, 8, 9], [4, 5]]

    groups =
      Enum.map(bindings, fn indexes ->
        members = Enum.map(indexes, &token(files, "vars.ex", "value", &1))
        %{definition: hd(members), members: members, references: members}
      end)

    groups = groups ++ variable_support_groups(files)
    {files, groups}
  end

  defp variable_support_groups(files) do
    Enum.map([{"first", 3}, {"nested", 2}, {"captured", 2}], fn {name, count} ->
      members = Enum.map(0..(count - 1), &token(files, "vars.ex", name, &1))
      %{definition: hd(members), members: members, references: members}
    end)
  end

  defp sdk_variable_project do
    files = %{
      "vars.ex" =>
        "defmodule SDKUser do\n  alias RemoteOps, as: Ops\n  def run(value) do\n    Ops.map([value], fn item -> {item, value} end)\n  end\nend\n"
    }

    values = Enum.map(0..2, &token(files, "vars.ex", "value", &1))
    items = Enum.map(0..1, &token(files, "vars.ex", "item", &1))
    call = token(files, "vars.ex", "map(", 0, 3)

    external = %{
      "uri" => "file:///fixture-sdk/remote_ops.ex",
      "range" => %{
        "start" => %{"line" => 10, "character" => 2},
        "end" => %{"line" => 10, "character" => 30}
      }
    }

    groups = [
      %{definition: hd(values), members: values, references: values},
      %{definition: hd(items), members: items, references: items},
      %{definition: external, members: [call], references: [call]}
    ]

    {files, groups, call}
  end

  defp module_alias_capture_project(consumer, destination, selected, aliases \\ []) do
    destination_module = String.trim_leading(destination, "Elixir.")

    files = %{
      "old.ex" => "defmodule Origin.Old do\n  def value(), do: :old\nend\n",
      "new.ex" => "defmodule #{destination_module} do\n  def value(), do: :unrelated\nend\n",
      "consumer.ex" => consumer
    }

    old = token(files, "old.ex", "Origin.Old")
    unrelated = token(files, "new.ex", destination_module)
    owner = token(files, "consumer.ex", "Consumer")

    old_members = [
      old,
      token(files, "consumer.ex", "Origin.Old"),
      token(files, "consumer.ex", selected <> ".value", 0, byte_size(selected))
    ]

    unrelated_members =
      [
        unrelated,
        token(files, "consumer.ex", destination <> ".value", 0, byte_size(destination))
      ] ++
        Enum.map(aliases, fn {name, occurrence} ->
          token(files, "consumer.ex", name, occurrence)
        end)

    values =
      Enum.map([{"old.ex", selected}, {"new.ex", destination}], fn {path, receiver} ->
        definition = token(files, path, "value")
        {offset, _length} = :binary.match(consumer, receiver <> ".value")
        call = token_offset(files, "consumer.ex", offset + byte_size(receiver) + 1, 5)
        %{definition: definition, members: [definition, call], references: [definition, call]}
      end)

    groups = [
      %{definition: old, members: old_members, references: old_members},
      %{definition: unrelated, members: unrelated_members, references: unrelated_members},
      %{definition: owner, members: [owner], references: [owner]}
      | values
    ]

    {files, groups}
  end

  defp nested_module_index_project do
    files = %{
      "outer.ex" => """
      defmodule Outer do
        defmodule Old do
          def value(), do: :old
        end
        def selected(), do: Old.value()
      end
      """,
      "caller.ex" => "defmodule NestedCaller do\n  def selected(), do: Outer.Old.value()\nend\n"
    }

    old = token(files, "outer.ex", "Old do", 0, 3)
    outer = token(files, "outer.ex", "Outer")
    caller = token(files, "caller.ex", "NestedCaller")
    value = token(files, "outer.ex", "value")

    members = [
      old,
      token(files, "outer.ex", "Old.value", 0, 3),
      token(files, "caller.ex", "Outer.Old")
    ]

    calls = [value, token(files, "outer.ex", "value", 1), token(files, "caller.ex", "value")]

    groups = [
      %{definition: old, members: members, references: members},
      %{definition: outer, members: [outer], references: [outer]},
      %{definition: caller, members: [caller], references: [caller]},
      %{definition: value, members: calls, references: calls}
    ]

    {files, groups}
  end

  defp module_project do
    files = %{
      "old.ex" =>
        "defmodule OldName do\n  def value(), do: 1\n  def self(), do: __MODULE__\nend\n",
      "uses.ex" =>
        "defmodule Uses do\n  alias OldName\n  def implicit(), do: OldName.value()\n  alias OldName, as: Stable\n  def explicit(), do: Stable.value()\n  require OldName, as: Required\n  def required(), do: Required.value()\n  def literal(), do: \"OldName Stable\"\nend\n"
    }

    {files, module_groups(files)}
  end

  defp module_groups(files) do
    old = token(files, "old.ex", "OldName")

    members = [
      old,
      token(files, "old.ex", "__MODULE__"),
      token(files, "uses.ex", "OldName", 0),
      token(files, "uses.ex", "OldName", 1),
      token(files, "uses.ex", "OldName", 2),
      token(files, "uses.ex", "OldName", 3),
      token(files, "uses.ex", "Stable.value", 0, 6),
      token(files, "uses.ex", "Required.value", 0, 8)
    ]

    refs =
      Enum.map(members, fn member ->
        put_in(member, ["range", "end"], member["range"]["start"])
      end)

    uses = token(files, "uses.ex", "Uses")
    value = token(files, "old.ex", "value", 0, 5)
    calls = Enum.map(0..2, &token(files, "uses.ex", "value", &1, 5))

    [
      %{definition: old, members: members, references: refs},
      %{definition: uses, members: [uses], references: [uses]},
      %{definition: value, members: [value | calls], references: [value | calls]}
    ]
  end

  defp install(fixture, files),
    do:
      Enum.each(files, fn {path, source} -> File.write!(Path.join(fixture.root, path), source) end)

  defp contents(fixture, files),
    do:
      Map.new(files, fn {path, _source} -> {path, File.read!(Path.join(fixture.root, path))} end)

  defp provider(fixture, files, groups, opts \\ []) do
    native_files = Keyword.get(opts, :native_files, files)

    versions =
      if Keyword.get(opts, :closed, false),
        do: %{},
        else: Map.new(files, fn {path, _source} -> {uri(fixture.root, path), 7} end)

    unknown = Keyword.get(opts, :unknown_snapshots, [])

    sources =
      Map.new(versions, fn {uri, version} ->
        path = URI.decode(URI.parse(uri).path) |> Path.relative_to(fixture.root)
        snapshot = if path in unknown, do: nil, else: Files.snapshot(native_files[path])
        {uri, %{version: version, snapshot: snapshot}}
      end)

    sources = if Keyword.get(opts, :untracked, false), do: %{}, else: sources
    {operators, operator_hovers} = __MODULE__.Provider.operator_facts(files)

    groups =
      Enum.map(groups ++ operators, fn group ->
        Map.new(group, fn {key, value} -> {key, qualify(value, fixture.root)} end)
      end)

    hovers =
      Enum.map(Keyword.get(opts, :hovers, []) ++ operator_hovers, fn %{
                                                                       location: location,
                                                                       markdown: markdown
                                                                     } ->
        %{
          location: qualify(location, fixture.root),
          result: %{
            "contents" => %{"kind" => "markdown", "value" => markdown},
            "range" => location["range"]
          }
        }
      end)

    state = %{
      groups: groups,
      versions: versions,
      sources: sources,
      notifications: [],
      root: fixture.root,
      session_id: fixture.context.session_id,
      files: files,
      native_files: native_files,
      mode: Keyword.get(opts, :mode),
      changed: false,
      server_info:
        Keyword.get(opts, :server_info, %{"name" => "ElixirLS", "version" => "0.31.1"}),
      hovers: hovers,
      namespace_modules: Keyword.get(opts, :namespace_modules, []),
      visible_variables: Keyword.get(opts, :visible_variables, []),
      workspace_symbols: Keyword.get(opts, :workspace_symbols)
    }

    start_supervised!({__MODULE__.Provider, state}, id: make_ref())
  end

  defp qualify(list, root) when is_list(list), do: Enum.map(list, &qualify(&1, root))

  defp qualify(%{"uri" => path} = location, root) do
    if String.starts_with?(path, "file://"),
      do: location,
      else: %{location | "uri" => uri(root, path)}
  end

  defp uri(root, path),
    do: "file://" <> URI.encode(Path.join(root, path), &(&1 == ?/ or URI.char_unreserved?(&1)))

  defp function_request(files, new_name),
    do: request(files, "math.ex", "product(x, y", new_name, 0, 7)

  defp request(files, path, needle, new_name, occurrence \\ 0, size \\ nil) do
    location = token(files, path, needle, occurrence, size)

    %{
      path: path,
      line: location["range"]["start"]["line"],
      character: location["range"]["start"]["character"],
      new_name: new_name,
      snapshot: Files.snapshot(files[path])
    }
  end

  defp binding_group(files, path, snippet, name) do
    {base, _length} = :binary.match(files[path], snippet)

    members =
      Enum.map(:binary.matches(snippet, name), fn {offset, _length} ->
        token_offset(files, path, base + offset, byte_size(name))
      end)

    %{definition: hd(members), members: members, references: members}
  end

  defp token(files, path, needle, occurrence \\ 0, size \\ nil) do
    source = Map.fetch!(files, path)
    {offset, _length} = source |> :binary.matches(needle) |> Enum.fetch!(occurrence)
    token_offset(files, path, offset, size || byte_size(needle))
  end

  defp token_offset(files, path, offset, size) do
    source = Map.fetch!(files, path)
    prefix = binary_part(source, 0, offset)
    lines = String.split(prefix, ~r/\r\n|\r|\n/)

    character =
      div(byte_size(:unicode.characters_to_binary(List.last(lines), :utf8, {:utf16, :little})), 2)

    length = size
    text = binary_part(source, offset, length)
    width = div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)
    first = %{"line" => length(lines) - 1, "character" => character}

    %{
      "uri" => path,
      "range" => %{"start" => first, "end" => %{first | "character" => character + width}}
    }
  end

  defmodule Host do
    @behaviour OhMyJido.Host
    def authorize(_context, _capability, _effect, _opts), do: :ok
    def credentials(_context, _account, _opts), do: {:error, :unavailable}
    def question(_context, _question, _opts), do: {:error, :unavailable}

    def invoke(context, capability, request, opts),
      do: OhMyJido.Host.Local.invoke(context, capability, request, opts)
  end

  # A deterministic native-navigation peer, not a rename implementation. It
  # supplies explicit per-binding/function identities. Production parsing must
  # discover additional clauses/import keys and reject missing/malformed facts.
  defmodule Provider do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(:document_versions, _from, state), do: {:reply, {:ok, state.versions}, state}
    def handle_call(:document_sources, _from, state), do: {:reply, {:ok, state.sources}, state}

    def handle_call(:notifications, _from, state),
      do: {:reply, Enum.reverse(state.notifications), state}

    def handle_call({:document_version, uri, operation, nil}, _from, state)
        when operation in [:open, :change] do
      version = Map.get(state.versions, uri, 0) + 1
      {:reply, {:ok, version}, %{state | versions: Map.put(state.versions, uri, version)}}
    end

    def handle_call({:notify, _method, _params}, _from, %{mode: :sync_denied} = state),
      do: {:reply, {:error, :native_sync_denied}, state}

    def handle_call({:notify, method, params}, _from, state) do
      document = params["textDocument"]

      text =
        if method == "textDocument/didOpen",
          do: document["text"],
          else: hd(params["contentChanges"])["text"]

      uri = document["uri"]
      path = URI.decode(URI.parse(uri).path) |> Path.relative_to(state.root)
      source = %{version: document["version"], snapshot: OhMyJido.Files.snapshot(text)}

      state = %{
        state
        | native_files: Map.put(state.native_files, path, text),
          sources: Map.put(state.sources, uri, source),
          notifications: [{method, params} | state.notifications]
      }

      state = if state.mode == :stale_receiver, do: resolve_receiver(state), else: state
      {:reply, :ok, state}
    end

    def handle_call({:bind, session_id, workspace}, _from, state) do
      result =
        if workspace == state.root and session_id == state.session_id,
          do:
            {:ok, %{session_id: session_id, workspace: workspace, server_info: state.server_info}},
          else: {:error, :wrong_workspace}

      {:reply, result, state}
    end

    def handle_call({:request, method, params, _timeout}, _from, state) do
      group = group_at(state.groups, params)
      state = change_source(state)
      result = request_result(method, params, group, state)
      {:reply, {:ok, result}, state}
    end

    defp request_result("textDocument/definition", params, group, %{mode: mode} = state)
         when mode in [:module_declaration_index, :empty_module_declaration_index] do
      if module_declaration?(params, state),
        do: if(mode == :empty_module_declaration_index, do: [], else: nil),
        else: definition_result(group, state)
    end

    defp request_result("textDocument/definition", params, group, %{mode: mode} = state)
         when mode in [:spec_self_definition, :spec_definition_cycle] do
      spec_location(params, group, state) || definition_result(group, state)
    end

    defp request_result("textDocument/definition", _params, group, state),
      do: definition_result(group, state)

    defp request_result("textDocument/completion", _params, group, state),
      do: completion(state, group)

    defp request_result("workspace/executeCommand", params, _group, state),
      do: execute_native(state, params)

    defp request_result("workspace/symbol", %{"query" => query}, _group, state),
      do: workspace_symbols(state, query)

    defp request_result("textDocument/hover", params, _group, state) do
      case Enum.find(state.hovers, &contains?(&1.location, params)) do
        nil -> nil
        hover -> hover.result
      end
    end

    defp request_result("textDocument/references", _params, group, state),
      do: reference_result(group, state)

    defp definition_result(_group, %{mode: :missing_definition}), do: nil
    defp definition_result(_group, %{mode: :malformed_definition}), do: %{"unexpected" => true}

    defp definition_result(group, %{mode: :location_flood}),
      do: if(group, do: List.duplicate(group.definition, 1_000), else: [])

    defp definition_result(nil, _state), do: nil

    defp definition_result(group, %{mode: :virtual_definition}),
      do: Map.update!(group.definition, "uri", &(&1 <> "?generated=1"))

    defp definition_result(group, %{mode: :all_clauses} = state) do
      if group.definition == hd(state.groups).definition,
        do: [group.definition, Enum.at(group.members, 1)],
        else: group.definition
    end

    defp definition_result(group, _state), do: group.definition

    defp reference_result(_group, %{mode: :missing_references}), do: []

    defp reference_result(group, %{mode: :out_of_root_reference}),
      do: [outside() | group.references]

    defp reference_result(group, %{mode: :literal_reference} = state),
      do: [literal(state) | group.references]

    defp reference_result(nil, _state), do: []
    defp reference_result(group, _state), do: group.references

    defp group_at(groups, params),
      do: Enum.find(groups, fn group -> Enum.any?(group.members, &contains?(&1, params)) end)

    defp module_declaration?(params, state) do
      Enum.any?(declarations(state.native_files, state.root), fn row ->
        row.kind == :module and row.uri == params["textDocument"]["uri"] and
          row.position == params["position"]
      end)
    end

    defp spec_location(params, group, state) do
      uri = params["textDocument"]["uri"]
      path = URI.decode(URI.parse(uri).path) |> Path.relative_to(state.root)
      content = Map.fetch!(state.native_files, path)

      {:ok, source} =
        OhMyJido.Intelligence.ElixirRename.Source.parse(%{path: path, content: content})

      token = Enum.find(source.tokens, &redirect_spec?(&1, params, group, state))
      if token, do: whole_spec_location(token, uri, content)
    end

    defp redirect_spec?(%{call_form: :spec_head} = token, params, group, state) do
      location = %{"uri" => params["textDocument"]["uri"], "range" => token.range}

      contains?(location, params) or
        (state.mode == :spec_definition_cycle and group == hd(state.groups))
    end

    defp redirect_spec?(_token, _params, _group, _state), do: false

    defp whole_spec_location(token, uri, content) do
      index = token.range["start"]["line"]
      line = content |> String.split("\n") |> Enum.at(index)
      {column, _length} = :binary.match(line, "@spec")

      %{
        "uri" => uri,
        "range" => %{
          "start" => %{"line" => index, "character" => column},
          "end" => %{"line" => index, "character" => byte_size(line)}
        }
      }
    end

    defp workspace_symbols(%{workspace_symbols: nil} = state, query) do
      for row <- declarations(state.native_files, state.root),
          row.kind == :module and String.contains?(row.module, query),
          do: workspace_symbol(row)
    end

    defp workspace_symbols(state, _query), do: state.workspace_symbols

    defp workspace_symbol(row) do
      line = row.declaration["line"]

      %{
        "name" => row.module,
        "kind" => 2,
        "location" => %{
          "uri" => row.uri,
          "range" => %{
            "start" => %{"line" => line, "character" => 0},
            "end" => %{"line" => line + 1, "character" => 0}
          }
        }
      }
    end

    def operator_facts(files) do
      exports = kernel_bindings()

      Enum.reduce(files, {[], []}, fn {path, source}, acc ->
        fold(parse(source), acc, &operator_fact(&1, &2, path, source, exports))
      end)
    end

    defp operator_fact({form, meta, args}, {groups, hovers} = acc, path, source, exports)
         when is_list(meta) and is_list(args) do
      name = word(form)
      binding = Enum.find(exports, &(&1.name == name and &1.arity == length(args)))

      if name in ~w(+ - * / ++ -- <> == != === !== < > <= >= =~ ! && || &&& ||| ^^^ ~~~ <<< >>> not and or in) and
           binding do
        first = point(source, meta)

        location = %{
          "uri" => path,
          "range" => %{
            "start" => first,
            "end" => Map.update!(first, "character", &(&1 + String.length(name)))
          }
        }

        external = %{
          "uri" => "file:///fixture-sdk/kernel.ex",
          "range" => %{
            "start" => %{"line" => 10, "character" => 2},
            "end" => %{"line" => 10, "character" => 30}
          }
        }

        arguments =
          if args == [],
            do: "",
            else: Enum.map_join(1..length(args), ", ", &"argument#{&1}")

        markdown = "```elixir\nKernel.#{name}(#{arguments})\n```\n\n*#{binding.kind}* \n"

        {[%{definition: external, members: [location], references: [location]} | groups],
         [%{location: location, markdown: markdown} | hovers]}
      else
        acc
      end
    end

    defp operator_fact(_node, acc, _path, _source, _exports), do: acc

    defp completion(%{mode: :malformed_completion}, _group),
      do: %{"items" => [], "isIncomplete" => true}

    defp completion(%{mode: :namespace_limit}, _group) do
      item = %{
        "label" => "Enum",
        "kind" => 9,
        "detail" => "module",
        "labelDetails" => %{"description" => "Enum"}
      }

      %{"items" => List.duplicate(item, 20_001), "isIncomplete" => true}
    end

    defp completion(state, _group) do
      names =
        Enum.map(declarations(state.native_files, state.root), & &1.module) ++
          ~w(Enum Kernel Kernel.SpecialForms ExUnit.Case Mix.Project) ++ state.namespace_modules

      items =
        Enum.map(names |> Enum.filter(&is_binary/1) |> Enum.uniq(), fn name ->
          %{
            "label" => name |> String.split(".") |> List.last(),
            "kind" => 9,
            "detail" => "module",
            "labelDetails" => %{"description" => name}
          }
        end)

      # Stock native0.31.1 also emits required-alias suggestions beside the
      # complete canonical namespace catalog; these do not occupy that namespace.
      required_alias = %{
        "label" => "Enumerations",
        "kind" => 9,
        "detail" => "alias",
        "labelDetails" => %{"description" => "alias GenLSP.Enumerations"}
      }

      erlang_module = %{
        "label" => ":application",
        "kind" => 8,
        "detail" => "behaviour",
        "labelDetails" => %{"description" => ":application"}
      }

      namespace_alias = %{
        "label" => "ElixirLS",
        "kind" => 9,
        "detail" => "alias",
        "labelDetails" => %{"description" => "ElixirLS", "detail" => "alias"}
      }

      %{
        "items" => [required_alias, namespace_alias, erlang_module | items],
        "isIncomplete" => true
      }
    end

    defp execute_native(state, %{
           "command" => "llmTypeInfo:oh_my_jido_rename",
           "arguments" => [name]
         }) do
      names =
        Enum.map(declarations(state.native_files, state.root), & &1.module) ++
          ~w(Enum Kernel Kernel.SpecialForms ExUnit.Case Mix.Project) ++ state.namespace_modules

      if name in names,
        do: %{
          "module" => name,
          "types" => [],
          "specs" => [],
          "callbacks" => [],
          "dialyzer_contracts" => []
        },
        else: %{"error" => "Module not found or not compiled"}
    end

    defp execute_native(%{mode: :malformed_completion}, %{
           "command" => "llmEnvironment:oh_my_jido_rename"
         }),
         do: %{"error" => "Unavailable parser environment"}

    defp execute_native(state, %{
           "command" => "llmEnvironment:oh_my_jido_rename",
           "arguments" => [location]
         }) do
      parts = String.split(location, ":")
      uri = parts |> Enum.slice(0..-3//1) |> Enum.join(":")
      [line, column] = Enum.map(Enum.slice(parts, -2..-1), &String.to_integer/1)
      path = URI.decode(URI.parse(uri).path) |> Path.relative_to(state.root)
      source = state.native_files[path]
      selected = point(source, line: line, column: column)
      declarations = declarations(state.native_files, state.root)

      caller =
        declarations
        |> Enum.filter(
          &(&1.kind == :function and &1.uri == uri and before?(&1.declaration, selected))
        )
        |> Enum.max_by(&{&1.declaration["line"], &1.declaration["character"]})

      import_context = %{
        caller: caller,
        selected: selected,
        groups: state.groups,
        source: source,
        declarations: declarations
      }

      imports = imports(parse(source), nil, nil, import_context, kernel_bindings())

      imported =
        Enum.map(imports, &%{"module" => &1.module, "function" => "#{&1.name}/#{&1.arity}"})

      definitions =
        for row <- declarations,
            row.kind == :function and row.uri == uri,
            arity <- row.arities,
            do: "#{row.module}.#{row.name}/#{arity}"

      extra_variables =
        if is_function(state.visible_variables, 1),
          do: state.visible_variables.(%{line: line, column: column}),
          else: state.visible_variables

      variables =
        Enum.map(
          Enum.uniq(caller.parameters ++ extra_variables),
          &%{"name" => &1, "version" => 0}
        )

      %{
        "location" => %{"uri" => uri, "line" => line, "column" => column},
        "context" => %{
          "module" => "Elixir." <> caller.module,
          "function" => "#{caller.name}/#{Enum.max(caller.arities)}"
        },
        "imports" => imported,
        "variables" => variables,
        "definitions" => %{"functions_defined" => Enum.uniq(definitions)}
      }
    end

    defp imports({form, meta, args}, module, function, %{caller: caller} = context, acc)
         when is_list(meta) do
      case {word(form), args} do
        {"quote", _args} ->
          acc

        {"defmodule", [name, body]} ->
          module_imports(name, body, module, context, acc)

        {definition, [head | body]} when definition in ["def", "defp", "defmacro", "defmacrop"] ->
          function_imports(head, body, module, context, acc)

        {"import", [target | options]} when module == caller.module ->
          import_bindings(target, options, meta, function, context, acc)

        _ ->
          imports(args, module, function, context, acc)
      end
    end

    defp imports(list, module, function, context, acc) when is_list(list),
      do: Enum.reduce(list, acc, &imports(&1, module, function, context, &2))

    defp imports({left, right}, module, function, context, acc),
      do: imports(right, module, function, context, imports(left, module, function, context, acc))

    defp imports(_literal, _module, _function, _context, acc), do: acc

    defp module_imports(name, body, module, context, acc) do
      name = module_name(name)

      full =
        if module && not String.contains?(name, "."), do: module <> "." <> name, else: name

      imports(body, full, nil, context, acc)
    end

    defp function_imports(head, body, module, %{caller: caller} = context, acc) do
      {name, _meta, arguments} = unguarded_head(head)

      if module == caller.module and word(name) == caller.name and
           length(arguments || []) == Enum.max(caller.arities),
         do: imports(body, module, caller.name, context, acc),
         else: acc
    end

    defp unguarded_head({guard, _meta, [head | _guards]}) when guard in [:when, "when"],
      do: head

    defp unguarded_head(head), do: head

    defp import_bindings(target, options, meta, function, %{caller: caller} = context, acc) do
      if (function == nil or function == caller.name) and
           before?(point(context.source, meta), context.selected) do
        imported_module = imported_module(target, context)

        available =
          imported_module
          |> available_imports(context.declarations)
          |> filter_imports(List.first(options))

        Enum.reject(acc, &(&1.module == imported_module)) ++ Enum.uniq(available)
      else
        acc
      end
    end

    defp imported_module(target, context) do
      first = point(context.source, elem(target, 1))
      params = %{"textDocument" => %{"uri" => context.caller.uri}, "position" => first}
      group = group_at(context.groups, params)

      declaration =
        if group,
          do:
            Enum.find(
              context.declarations,
              &(&1.kind == :module and declaration_at?(&1, group.definition))
            )

      if declaration, do: declaration.module, else: module_name(target)
    end

    defp available_imports("Kernel", _declarations), do: kernel_bindings()

    defp available_imports(module, declarations) do
      for row <- declarations,
          row.kind == :function and row.module == module and row.public,
          arity <- row.arities,
          do: %{
            module: row.module,
            name: row.name,
            arity: arity,
            kind: row.callable_kind
          }
    end

    defp filter_imports(available, options),
      do: filter_imports(available, option(options, "only"), option(options, "except"))

    defp filter_imports(available, only, _except) when is_list(only),
      do: Enum.filter(available, &listed_import?(&1, only))

    defp filter_imports(available, _only, except) when is_list(except),
      do: Enum.reject(available, &listed_import?(&1, except))

    defp filter_imports(available, _only, _except), do: available

    defp listed_import?(entry, qualifiers),
      do:
        Enum.any?(qualifiers, fn {name, arity} ->
          word(name) == entry.name and arity == entry.arity
        end)

    defp option(options, key) when is_list(options),
      do: Enum.find_value(options, fn {name, value} -> if word(name) == key, do: value end)

    defp option(_options, _key), do: nil

    defp before?(left, right),
      do: {left["line"], left["character"]} <= {right["line"], right["character"]}

    defp kernel_bindings do
      for {kind, exports} <- [
            {"function", Kernel.__info__(:functions)},
            {"macro", Kernel.__info__(:macros)}
          ],
          {name, arity} <- exports,
          do: %{module: "Kernel", name: Atom.to_string(name), arity: arity, kind: kind}
    end

    defp declarations(files, root) do
      Enum.flat_map(files, fn {path, source} ->
        uri =
          "file://" <> URI.encode(Path.join(root, path), &(&1 == ?/ or URI.char_unreserved?(&1)))

        collect(parse(source), nil, uri, source, [])
      end)
    end

    defp collect({form, meta, args}, module, uri, source, acc) when is_list(meta) do
      case {word(form), args} do
        {"quote", _args} ->
          acc

        {"defmodule", [name, body]} ->
          collect_module(name, body, meta, module, uri, source, acc)

        {definition, [head | _body]}
        when definition in [
               "def",
               "defp",
               "defmacro",
               "defmacrop",
               "defguard",
               "defguardp",
               "defdelegate"
             ] ->
          collect_function(unguarded_head(head), definition, meta, module, uri, source, acc)

        _ ->
          collect(args, module, uri, source, acc)
      end
    end

    defp collect(list, module, uri, source, acc) when is_list(list),
      do: Enum.reduce(list, acc, &collect(&1, module, uri, source, &2))

    defp collect({left, right}, module, uri, source, acc),
      do: collect(right, module, uri, source, collect(left, module, uri, source, acc))

    defp collect(_literal, _module, _uri, _source, acc), do: acc

    defp collect_module(name, body, meta, module, uri, source, acc) do
      name_text = module_name(name)

      if name_text do
        full =
          if module && not String.contains?(name_text, "."),
            do: module <> "." <> name_text,
            else: String.trim_leading(name_text, "Elixir.")

        row = %{
          kind: :module,
          module: full,
          uri: uri,
          declaration: point(source, meta),
          position: point(source, elem(name, 1))
        }

        collect(body, full, uri, source, [row | acc])
      else
        acc
      end
    end

    defp collect_function(
           {name, head_meta, arguments},
           definition,
           meta,
           module,
           uri,
           source,
           acc
         )
         when is_list(head_meta) do
      arguments = arguments || []
      arity = length(arguments)

      defaults =
        Enum.count(arguments, fn
          {operator, _meta, _args} -> word(operator) == "\\\\"
          _argument -> false
        end)

      row = %{
        kind: :function,
        module: module,
        uri: uri,
        declaration: point(source, meta),
        position: point(source, head_meta),
        name: word(name),
        arities: Enum.to_list((arity - defaults)..arity),
        callable_kind:
          if(definition in ["def", "defp", "defdelegate"], do: "function", else: "macro"),
        public: definition not in ["defp", "defmacrop", "defguardp"],
        parameters: parameter_names(arguments)
      }

      [row | acc]
    end

    defp collect_function(_head, _definition, _meta, _module, _uri, _source, acc), do: acc

    defp parameter_names(arguments),
      do: arguments |> fold([], &collect_parameter/2) |> Enum.uniq()

    defp collect_parameter({name, _meta, nil}, acc) when is_atom(name) or is_binary(name) do
      name = word(name)
      if name == "_" or String.starts_with?(name, "__"), do: acc, else: [name | acc]
    end

    defp collect_parameter(_node, acc), do: acc

    defp declaration_at?(row, location) do
      row.uri == location["uri"] and location["range"]["start"] in [row.declaration, row.position]
    end

    defp parse(source) do
      case Code.string_to_quoted(source,
             columns: true,
             token_metadata: true,
             static_atoms_encoder: fn value, _meta -> {:ok, value} end,
             emit_warnings: false
           ) do
        {:ok, ast} -> ast
        {:error, _reason} -> nil
      end
    end

    defp module_name({aliases, _meta, names}) when aliases in [:__aliases__, "__aliases__"],
      do: Enum.map_join(names, ".", &word/1)

    defp module_name(_ast), do: nil
    defp word(value) when is_atom(value), do: Atom.to_string(value)
    defp word(value) when is_binary(value), do: value
    defp word(_value), do: nil

    defp point(source, meta) do
      line = Enum.at(String.split(source, ~r/\r\n|\r|\n/), meta[:line] - 1)
      %{"line" => meta[:line] - 1, "character" => units(line, meta[:column] - 1, 0)}
    end

    defp units(_text, 0, acc), do: acc

    defp units(<<codepoint::utf8, rest::binary>>, count, acc),
      do: units(rest, count - 1, acc + if(codepoint > 0xFFFF, do: 2, else: 1))

    defp fold({form, meta, args} = node, acc, fun) when is_list(meta) do
      acc = fun.(node, acc)
      acc = if is_tuple(form), do: fold(form, acc, fun), else: acc
      fold(args, acc, fun)
    end

    defp fold(list, acc, fun) when is_list(list), do: Enum.reduce(list, acc, &fold(&1, &2, fun))
    defp fold({left, right}, acc, fun), do: fold(right, fold(left, acc, fun), fun)
    defp fold(_literal, acc, _fun), do: acc

    # This fixture's only mutable semantic edge is an explicitly qualified
    # Alpha.foo/0 versus Bravo.foo/0. Recompute it from RECEIVED buffer AST, not
    # disk contents or a requested new name, to expose stale-buffer mistakes.
    defp resolve_receiver(state) do
      source = state.native_files["caller.ex"]

      receivers =
        fold(parse(source), [], fn
          {{dot, _dot_meta, [receiver, name]}, _meta, []}, acc when dot in [:., "."] ->
            if word(name) == "foo",
              do: [{module_name(receiver), elem(receiver, 1)} | acc],
              else: acc

          _node, acc ->
            acc
        end)

      [{receiver, receiver_meta}] = receivers
      caller_uri = "file://" <> Path.join(state.root, "caller.ex")
      first = point(source, receiver_meta)

      qualifier = %{
        "uri" => caller_uri,
        "range" => %{
          "start" => first,
          "end" => Map.update!(first, "character", &(&1 + String.length(receiver)))
        }
      }

      group =
        Enum.find(
          state.groups,
          &Enum.any?(&1.members, fn member -> member["uri"] == caller_uri end)
        )

      [call] = Enum.filter(group.members, &(&1["uri"] == caller_uri))
      declarations = declarations(state.native_files, state.root)

      definition =
        Enum.find(
          declarations,
          &(&1.kind == :function and &1.module == receiver and &1.name == "foo")
        )

      module = Enum.find(declarations, &(&1.kind == :module and &1.module == receiver))

      groups =
        Enum.map(state.groups, fn group ->
          # Definitions reflect current received buffers, while compiled trace
          # references deliberately remain stale until a real native build.
          group = %{group | members: Enum.reject(group.members, &(&1["uri"] == caller_uri))}

          cond do
            declaration_at?(definition, group.definition) ->
              %{group | members: [call | group.members]}

            declaration_at?(module, group.definition) ->
              %{group | members: [qualifier | group.members]}

            true ->
              group
          end
        end)

      %{state | groups: groups}
    end

    defp contains?(location, params) do
      first = location["range"]["start"]
      last = location["range"]["end"]
      selected = params["position"]

      location["uri"] == params["textDocument"]["uri"] and first["line"] == selected["line"] and
        first["character"] <= selected["character"] and selected["character"] < last["character"]
    end

    defp change_source(%{mode: :change_source, changed: false} = state) do
      File.write!(
        Path.join(state.root, "math.ex"),
        state.files["math.ex"] <> "# external change\n"
      )

      %{state | changed: true}
    end

    defp change_source(%{mode: :change_versions, changed: false} = state) do
      %{
        state
        | versions: Map.new(state.versions, fn {uri, version} -> {uri, version + 1} end),
          changed: true
      }
    end

    defp change_source(%{mode: :change_fingerprints, changed: false} = state) do
      sources =
        Map.new(state.sources, fn {uri, source} ->
          {uri, %{source | snapshot: OhMyJido.Files.snapshot("changed without a version bump")}}
        end)

      %{state | sources: sources, changed: true}
    end

    defp change_source(state), do: state

    defp outside,
      do: %{
        "uri" => "file:///outside-rename.ex",
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 7}
        }
      }

    defp literal(state) do
      source = state.files["user.ex"]
      prefix = source |> String.split("# product") |> hd()
      line = length(String.split(prefix, "\n")) - 1

      %{
        "uri" => "file://" <> Path.join(state.root, "user.ex"),
        "range" => %{
          "start" => %{"line" => line, "character" => 4},
          "end" => %{"line" => line, "character" => 11}
        }
      }
    end
  end
end
