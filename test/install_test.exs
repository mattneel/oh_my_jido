defmodule OhMyJido.InstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OhMyJido.Install

  @source Path.expand("..", __DIR__)

  @consumer """
  defmodule InstallConsumer.MixProject do
    use Mix.Project

    def project do
      [app: :install_consumer, version: "0.1.0", deps: deps(), preferred_cli_env: [check: :test]]
    end

    def application, do: [extra_applications: [:logger]]

    defp deps do
      [{:kept, "~> 1.0", only: [:dev, :test], runtime: false}]
    end
  end
  """

  setup do
    target = Path.join(System.tmp_dir!(), "omj-install-#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf!(target) end)
    %{target: target}
  end

  test "native application produces usable root dependencies without changing host configuration",
       %{
         target: target
       } do
    igniter = fixture() |> Install.plan(source: @source)

    assert igniter.issues == []
    assert {:ok, applied, %{tasks: [], warnings: []}} = Igniter.Test.apply_igniter(igniter)
    files = applied.assigns.test_files
    assert files["config/config.exs"] == "raise \"host config must not execute\"\n"
    assert files["lib/kept.ex"] == "defmodule Kept, do: nil\n"

    project = consumer_project!(target, files["mix.exs"])
    assert project.app == :install_consumer
    assert project.preferred_cli_env == [check: :test]
    assert project.application == [extra_applications: [:logger]]
    assert {:kept, "~> 1.0", only: [:dev, :test], runtime: false} in project.deps
    assert {:oh_my_jido, path: @source} in project.deps
    assert {:jido, path: Path.join(@source, "vendor/jido"), override: true} in project.deps
    assert {:req_llm, path: Path.join(@source, "vendor/req_llm"), override: true} in project.deps
    assert {:jido_ai, path: Path.join(@source, "vendor/jido_ai"), override: true} in project.deps

    assert {:jido_action, path: Path.join(@source, "vendor/jido_action"), override: true} in project.deps

    assert {:jido_signal,
            git: "https://github.com/agentjido/jido_signal.git",
            ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
            override: true} in project.deps

    assert {:zoi,
            git: "https://github.com/mikehostetler/zoi.git",
            ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
            override: true} in project.deps

    refute Enum.any?(project.deps, &(elem(&1, 0) in [:snakepit, :igniter, :quickbeam]))
  end

  test "Snakepit is explicitly selected and never scheduled for startup", %{target: target} do
    igniter = fixture() |> Install.plan(source: @source, snakepit: true)
    assert {:ok, applied, %{tasks: []}} = Igniter.Test.apply_igniter(igniter)
    project = consumer_project!(target, applied.assigns.test_files["mix.exs"])

    assert {:snakepit,
            path: Path.join(@source, "vendor/snakepit"), override: true, runtime: false} in project.deps

    assert project.application == [extra_applications: [:logger]]
  end

  test "the same source and exact pins are idempotent" do
    first = fixture() |> Install.plan(source: @source) |> Igniter.Test.apply_igniter!()
    again = Install.plan(first, source: @source)

    assert again.issues == []
    refute Igniter.has_changes?(again)
    assert again.tasks == []
  end

  test "native Igniter task composition stages the same usable dependency plan", %{target: target} do
    igniter =
      Igniter.Mix.Task.configure_and_run(
        fixture(),
        Mix.Tasks.OhMyJido.Install,
        ["--source", @source, "--snakepit", "--dry-run"]
      )

    assert {:ok, applied, %{tasks: []}} = Igniter.Test.apply_igniter(igniter)
    project = consumer_project!(target, applied.assigns.test_files["mix.exs"])

    assert {:snakepit,
            path: Path.join(@source, "vendor/snakepit"), override: true, runtime: false} in project.deps
  end

  test "equivalent exact source revisions and reordered options are preserved", %{target: target} do
    existing =
      "{:jido_signal, override: true, ref: \"fd8d00555d6a64b4109619f4c26f1b75e8a91d41\", git: \"https://github.com/agentjido/jido_signal.git\"}"

    mix = String.replace(@consumer, "[{:kept,", "[#{existing}, {:kept,")
    igniter = fixture(mix) |> Install.plan(source: @source)
    assert {:ok, applied, _} = Igniter.Test.apply_igniter(igniter)
    project = consumer_project!(target, applied.assigns.test_files["mix.exs"])

    assert {:jido_signal,
            override: true,
            ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
            git: "https://github.com/agentjido/jido_signal.git"} in project.deps

    assert Enum.count(project.deps, &(elem(&1, 0) == :jido_signal)) == 1
  end

  test "equivalent existing relative source paths and option order are retained", %{
    target: target
  } do
    File.cd!(target, fn ->
      relative =
        Igniter.Util.BackwardsCompat.relative_to_cwd(Path.join(@source, "vendor/jido"),
          force: true
        )

      existing = "{:jido, override: true, path: #{inspect(relative)}}"
      mix = String.replace(@consumer, "[{:kept,", "[#{existing}, {:kept,")
      igniter = fixture(mix) |> Install.plan(source: @source)

      assert {:ok, applied, _} = Igniter.Test.apply_igniter(igniter)
      project = consumer_project!(target, applied.assigns.test_files["mix.exs"])
      assert Enum.count(project.deps, &(elem(&1, 0) == :jido)) == 1
      assert {:jido, override: true, path: relative} in project.deps
    end)
  end

  test "incompatible dependencies are refused without partially adding other pins" do
    for declaration <- [
          "{:jido, \"~> 3.0\"}",
          "{:req_llm, path: \"somewhere_else\", override: true}",
          "{:jido_ai, \"== 2.4.0\"}",
          "{:jido_ai, path: \"somewhere_else\", override: true}",
          "{:jido_action, \"== 2.4.0\", override: true}",
          "{:jido_signal, \"== 2.4.0\", override: true}",
          "{:zoi, \"~> 0.18\"}",
          "{:oh_my_jido, git: \"https://example.invalid/host-choice.git\"}"
        ] do
      mix = String.replace(@consumer, "[{:kept,", "[#{declaration}, {:kept,")
      igniter = fixture(mix) |> Install.plan(source: @source)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "Existing dependency"))
      refute Igniter.has_changes?(igniter)
      assert igniter.tasks == []
      assert {:error, _} = Igniter.Test.apply_igniter(igniter)
    end
  end

  test "nonliteral managed options are never evaluated" do
    existing = "{:jido, path: raise(\"must not execute\"), override: true}"
    mix = String.replace(@consumer, "[{:kept,", "[#{existing}, {:kept,")
    igniter = fixture(mix) |> Install.plan(source: @source)

    assert Enum.any?(igniter.issues, &String.contains?(&1, "Existing dependency :jido"))
    refute Igniter.has_changes?(igniter)
  end

  test "unrelated dynamic dependency options remain host expressions", %{target: target} do
    mix = String.replace(@consumer, "only: [:dev, :test]", "only: [Mix.env()]")
    igniter = fixture(mix) |> Install.plan(source: @source)
    assert {:ok, applied, _} = Igniter.Test.apply_igniter(igniter)
    project = consumer_project!(target, applied.assigns.test_files["mix.exs"])
    assert {:kept, "~> 1.0", only: [:dev], runtime: false} in project.deps
  end

  test "ambiguous dependency declarations and unsupported project layouts are refused" do
    for mix <- [
          String.replace(@consumer, "[{:kept,", "[unknown_dependency(), {:kept,"),
          String.replace(
            @consumer,
            "[{:kept,",
            "[{:jido_ai, path: \"duplicate\", override: true}, {:jido_ai, path: \"duplicate\", override: true}, {:kept,"
          ),
          String.replace(@consumer, "deps: deps()", "deps: []"),
          String.replace(
            @consumer,
            "app: :install_consumer",
            "apps_path: \"apps\", app: :install_consumer"
          ),
          String.replace(@consumer, "app: :install_consumer", "app: :oh_my_jido"),
          String.replace(
            @consumer,
            "[{:kept, \"~> 1.0\", only: [:dev, :test], runtime: false}]",
            "custom_deps()"
          )
        ] do
      igniter = fixture(mix) |> Install.plan(source: @source)
      assert igniter.issues != []
      refute Igniter.has_changes?(igniter)
    end
  end

  test "missing or incorrectly versioned snapshots are rejected before editing", %{target: target} do
    for options <- [
          [source: Path.join(target, "missing")],
          [source: @source, snakepit: "yes"],
          [source: @source, unexpected: true],
          [source: @source, source: @source]
        ] do
      igniter = Install.plan(fixture(), options)
      assert igniter.issues != []
      refute Igniter.has_changes?(igniter)
    end

    source = Path.join(target, "wrong-source")
    File.mkdir_p!(Path.join(source, "vendor/jido"))
    File.write!(Path.join(source, "mix.exs"), "raise \"source project must not execute\"\n")

    File.write!(
      Path.join(source, "vendor/jido/mix.exs"),
      "raise \"vendor project must not execute\"\n"
    )

    File.write!(
      Path.join(source, "vendor/jido/UPSTREAM.json"),
      ~s({"package":"jido","version":"3.0.0"})
    )

    igniter = Install.plan(fixture(), source: source)
    assert Enum.any?(igniter.issues, &String.contains?(&1, "3.0.0-beta.1"))
    refute Igniter.has_changes?(igniter)
  end

  test "all native V3 snapshots require their exact source provenance", %{target: target} do
    for app <- [:jido, :jido_ai, :jido_action],
        alteration <- [:missing_manifest, :wrong_ref, :legacy_manifest] do
      source = source_fixture!(Path.join(target, "#{app}-#{alteration}"))
      path = Path.join([source, "vendor", Atom.to_string(app), "UPSTREAM.json"])

      case alteration do
        :missing_manifest ->
          File.rm!(path)

        :wrong_ref ->
          manifest = path |> File.read!() |> Jason.decode!()
          File.write!(path, Jason.encode!(Map.put(manifest, "ref", String.duplicate("0", 40))))

        :legacy_manifest ->
          File.write!(
            path,
            Jason.encode!(%{
              "package" => Atom.to_string(app),
              "version" => "2.4.0",
              "privacy_boundary_updates" => %{}
            })
          )
      end

      igniter = Install.plan(fixture(), source: source)
      assert Enum.any?(igniter.issues, &String.contains?(&1, "#{app} native V3"))
      refute Igniter.has_changes?(igniter)
      assert igniter.tasks == []
    end
  end

  test "dry-run never evaluates target executable configuration or writes target files", %{
    target: target
  } do
    files = disk_fixture!(target)

    output =
      capture_io(fn ->
        File.cd!(target, fn ->
          assert {:ok, :dry_run_with_changes} =
                   Install.run(["--source", @source, "--dry-run"])
        end)
      end)

    assert output =~ "vendored native Jido V3 Core and AI"
    assert output =~ "Jido.Action ref 19c77f94"
    assert output =~ "Jido.Signal ref fd8d0055"
    assert output =~ "vendor/jido_ai"
    refute output =~ "Jido.AI/Jido.Action == 2.4.0"
    refute output =~ "patched Jido 2.4.0"

    for {path, content} <- files, do: assert(File.read!(Path.join(target, path)) == content)
    assert Enum.sort(File.ls!(target)) == [".formatter.exs", ".igniter.exs", "config", "mix.exs"]
    refute File.exists?(Path.join(target, "deps"))
    refute File.exists?(Path.join(target, "_build"))
  end

  test "application requires both explicit mutation and acknowledgement flags", %{target: target} do
    disk_fixture!(target)

    File.cd!(target, fn ->
      for argv <- [
            ["--source", @source, "--apply"],
            ["--source", @source, "--yes"],
            ["--source", @source, "--apply", "--yes", "--dry-run"],
            ["--source", @source, "--unexpected"],
            ["--source", @source, "--source", @source],
            ["--source", @source, "--dry-run", "--dry-run"]
          ] do
        assert {:error, _} = Install.run(argv)
        assert File.read!("mix.exs") == @consumer
      end
    end)
  end

  test "a conflicting dependency prevents controlled application from writing anything", %{
    target: target
  } do
    files = disk_fixture!(target)
    mix = String.replace(@consumer, "[{:kept,", "[{:jido_ai, \"~> 3.0\"}, {:kept,")
    File.write!(Path.join(target, "mix.exs"), mix)

    capture_io(fn ->
      File.cd!(target, fn ->
        assert {:error, _} = Install.run(["--source", @source, "--apply", "--yes"])
      end)
    end)

    assert File.read!(Path.join(target, "mix.exs")) == mix

    for {path, content} <- Map.delete(files, "mix.exs") do
      assert File.read!(Path.join(target, path)) == content
    end

    refute File.exists?(Path.join(target, "mix.lock"))
    refute File.exists?(Path.join(target, "deps"))
    refute File.exists?(Path.join(target, "_build"))
  end

  test "controlled application writes only the planned consumer dependency change", %{
    target: target
  } do
    files = disk_fixture!(target)

    capture_io(fn ->
      File.cd!(target, fn ->
        assert {:ok, :changes_made} = Install.run(["--source", @source, "--apply", "--yes"])
        assert {:ok, :dry_run_with_no_changes} = Install.run(["--source", @source, "--dry-run"])
      end)
    end)

    project = consumer_project!(target, File.read!(Path.join(target, "mix.exs")))
    assert {:jido_ai, path: Path.join(@source, "vendor/jido_ai"), override: true} in project.deps

    assert {:jido_action, path: Path.join(@source, "vendor/jido_action"), override: true} in project.deps

    assert {:jido_signal,
            git: "https://github.com/agentjido/jido_signal.git",
            ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
            override: true} in project.deps

    assert {:jido, path: Path.join(@source, "vendor/jido"), override: true} in project.deps

    for {path, content} <- Map.delete(files, "mix.exs") do
      assert File.read!(Path.join(target, path)) == content
    end

    refute File.exists?(Path.join(target, "mix.lock"))
    refute File.exists?(Path.join(target, "deps"))
    refute File.exists?(Path.join(target, "_build"))
  end

  test "ordinary consumers can compile installer tooling without optional Igniter or Boundary", %{
    target: target
  } do
    installer = Path.join(@source, "lib/oh_my_jido/install.ex")
    task = Path.join(@source, "lib/mix/tasks/oh_my_jido.install.ex")

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "-r",
          installer,
          "-r",
          task,
          "-e",
          "false = Code.ensure_loaded?(Igniter); false = Code.ensure_loaded?(Boundary); " <>
            "{:error, message} = OhMyJido.Install.run([]); " <>
            "true = String.contains?(message, \"install.exs\"); " <>
            "try do Mix.Tasks.OhMyJido.Install.run([]) rescue " <>
            "e in Mix.Error -> IO.puts(Exception.message(e)) end"
        ],
        cd: target,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    assert output =~ "Igniter"
    assert output =~ "install.exs"
    refute output =~ "warning:"
  end

  test "isolated preview and apply never expand authored macros", %{target: target} do
    disk_fixture!(target)
    marker = Path.join(target, "macro-evaluated")

    macro = """
    import ExAST.Selector, only: [where: 2]
    where(nil, comment((File.write!(#{inspect(marker)}, "executed"); "x")))
    """

    mix = String.replace(@consumer, "use Mix.Project", macro <> "\nuse Mix.Project")
    File.write!(Path.join(target, "mix.exs"), mix)
    installer = Path.join(@source, "lib/oh_my_jido/install.ex")

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.reject(
        &(String.ends_with?(&1, "/oh_my_jido/ebin") or String.ends_with?(&1, "/boundary/ebin"))
      )
      |> Enum.flat_map(&["-pa", &1])

    script = """
    Mix.start()
    Code.require_file(#{inspect(installer)})
    nil = Process.whereis(Rewrite.TaskSupervisor)
    {:ok, :dry_run_with_changes} = OhMyJido.Install.run(["--source", #{inspect(@source)}, "--dry-run"])
    false = File.exists?(#{inspect(marker)})
    {:ok, :changes_made} = OhMyJido.Install.run(["--source", #{inspect(@source)}, "--apply", "--yes"])
    false = File.exists?(#{inspect(marker)})
    {:ok, :dry_run_with_no_changes} = OhMyJido.Install.run(["--source", #{inspect(@source)}, "--dry-run"])
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        paths ++ ["-e", script],
        cd: target,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    refute File.exists?(marker)
  end

  defp source_fixture!(source) do
    File.mkdir_p!(source)
    File.write!(Path.join(source, "mix.exs"), "raise \"source project must not execute\"\n")

    for app <- [:jido, :jido_ai, :jido_action, :req_llm] do
      directory = Path.join([source, "vendor", Atom.to_string(app)])
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "mix.exs"), "raise \"vendor project must not execute\"\n")

      File.cp!(
        Path.join([@source, "vendor", Atom.to_string(app), "UPSTREAM.json"]),
        Path.join(directory, "UPSTREAM.json")
      )
    end

    source
  end

  defp fixture(mix \\ @consumer) do
    Install.new()
    |> Igniter.assign(:test_mode?, true)
    |> Igniter.assign(:test_files, %{
      "mix.exs" => mix,
      "config/config.exs" => "raise \"host config must not execute\"\n",
      "lib/kept.ex" => "defmodule Kept, do: nil\n"
    })
  end

  defp disk_fixture!(target) do
    files = %{
      "mix.exs" => @consumer,
      ".formatter.exs" => "raise \"formatter must not execute\"\n",
      ".igniter.exs" => "raise \"igniter config must not execute\"\n",
      "config/config.exs" => "raise \"host config must not execute\"\n"
    }

    Enum.each(files, fn {path, content} ->
      file = Path.join(target, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end)

    files
  end

  defp consumer_project!(target, content) do
    File.write!(Path.join(target, "mix.exs"), content)

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "-e",
          "Mix.start(); Code.require_file(\"mix.exs\"); " <>
            "config = Mix.Project.config(); " <>
            "project = %{app: config[:app], deps: config[:deps], " <>
            "preferred_cli_env: config[:preferred_cli_env], " <>
            "application: Mix.Project.get!().application()}; " <>
            "IO.write(Base.encode64(:erlang.term_to_binary(project)))"
        ],
        cd: target,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}, {"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    output |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end
end
