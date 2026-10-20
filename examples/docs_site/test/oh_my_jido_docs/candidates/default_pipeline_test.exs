defmodule OhMyJidoDocs.Candidates.DefaultPipelineTest do
  use OhMyJidoDocs.DataCase, async: false

  import OhMyJidoDocs.CandidateFixtures

  alias OhMyJidoDocs.{Candidates, DataCase, Editor}
  alias OhMyJidoDocs.Candidates.{Execution, Runner, Source}

  @moduletag :candidate_integration
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  @default_mix_steps [
    {"test", ["deps.compile"]},
    {"test", ["compile", "--warnings-as-errors"]},
    {"test", ["test", "--exclude", "candidate_integration"]},
    {"prod", ["deps.compile"]},
    {"prod", ["compile", "--warnings-as-errors"]},
    {"prod", ["assets.deploy"]},
    {"prod", ["release", "--overwrite"]}
  ]

  @default_dependencies ~w(
    bandit esbuild heroicons hpax jason mime phoenix phoenix_pubsub phoenix_template
    plug plug_crypto tailwind telemetry thousand_island websock websock_adapter
  )

  setup %{tmp_dir: temporary} do
    {:ok, setup_fixture(temporary, default_pipeline: true)}
  end

  test "the complete default pipeline builds private Phoenix assets and a production release",
       fixture do
    assert :error = Application.fetch_env(:oh_my_jido_docs, :candidate_check_steps)
    assert :ok = Execution.check_available()
    assert {:ok, trusted_dependencies} = Source.manifest(Path.join(fixture.app, "deps"))
    assert {:ok, dependencies} = File.ls(Path.join(fixture.app, "deps"))
    assert Enum.sort(dependencies) == @default_dependencies
    cached_dependencies = Path.expand("../../../deps", __DIR__)
    project = File.read!(Path.join(fixture.app, "mix.exs"))

    for name <- @default_dependencies do
      cached = Path.join(cached_dependencies, name)

      assert {:ok, manifest} = Source.manifest(cached),
             "Required cached dependency source #{name} is unavailable at #{cached}"

      assert :ok = Source.verify(Path.join([fixture.app, "deps", name]), manifest)
      assert project =~ "{:#{name}, path: \"deps/#{name}\", override: true"
    end

    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Real default pipeline\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)

    checked = check!(candidate, 660_000)
    context = checked.check_receipt["context"]
    steps = checked.check_receipt["steps"]
    mix_steps = Enum.reject(steps, &(&1["phase"] == "dependency_preflight"))
    preflights = Enum.filter(steps, &(&1["phase"] == "dependency_preflight"))

    assert Enum.map(mix_steps, &{&1["mix_env"], &1["args"]}) == @default_mix_steps
    assert Enum.map(preflights, & &1["mix_env"]) == ["test", "prod"]

    for step <- steps do
      assert step["status"] == "passed", step["output"]
      assert step["exit_status"] == 0
      assert step["effect"] == "completed"
      assert step["cwd"] == context["app"]
    end

    assert context["app"] == Path.join(context["source"], "examples/docs_site")
    assert context["deps"] == Path.join(context["app"], "deps")
    assert Execution.environment(context, "prod")["MIX_DEPS_PATH"] == context["deps"]
    assert context["dependency_digest"] == Source.digest(trusted_dependencies)
    refute File.exists?(Path.join(context["root"], "deps"))
    assert File.regular?(Path.join(context["source"], "lib/candidate_library.ex"))
    assert File.regular?(Path.join(context["deps"], "phoenix/priv/static/phoenix.mjs"))

    assert File.regular?(
             Path.join(context["deps"], "heroicons/optimized/24/outline/book-open.svg")
           )

    expected_dependency_paths =
      [context["source"] | Enum.map(@default_dependencies, &Path.join(context["deps"], &1))]
      |> Enum.sort()

    for preflight <- preflights do
      assert preflight["dependency_paths"] == expected_dependency_paths
      assert preflight["native_artifacts"] == []

      assert Enum.all?(preflight["dependency_paths"], fn path ->
               path == context["source"] or String.starts_with?(path, context["deps"] <> "/")
             end)
    end

    release = checked.check_receipt["release"]
    assert File.regular?(release)
    assert {:ok, ^release} = Runner.available(release)
    release_root = release |> Path.dirname() |> Path.dirname()
    released_priv = Path.join(release_root, "lib/candidate_fixture-0.1.0/priv")
    source_static = Path.join(context["app"], "priv/static")
    released_static = Path.join(released_priv, "static")

    css = File.read!(Path.join(source_static, "assets/css/app.css"))
    assert css =~ ".hero-book-open"
    assert css =~ "data:image/svg+xml"
    assert css =~ "--hero-book-open"
    javascript = File.read!(Path.join(source_static, "assets/js/app.js"))
    assert javascript =~ "candidatePipeline"
    assert byte_size(javascript) > 1_000
    assert File.read!(Path.join(released_static, "assets/css/app.css")) == css
    assert File.read!(Path.join(released_static, "assets/js/app.js")) == javascript
    assert File.read!(Path.join(released_priv, "docs/index.md")) == "# Real default pipeline\n"

    assert %{"latest" => latest} =
             source_static |> Path.join("cache_manifest.json") |> File.read!() |> Jason.decode!()

    for logical <- ["assets/css/app.css", "assets/js/app.js"] do
      fingerprinted = Map.fetch!(latest, logical)
      refute fingerprinted == logical
      assert File.regular?(Path.join(source_static, fingerprinted))
      assert File.regular?(Path.join(released_static, fingerprinted))
      assert File.regular?(Path.join(released_static, fingerprinted <> ".gz"))
    end

    assert [_phoenix_endpoint] =
             Path.wildcard(
               Path.join(release_root, "lib/phoenix-*/ebin/Elixir.Phoenix.Endpoint.beam")
             )

    assert :ok = Execution.verify_context(candidate, context)
    assert :ok = Source.verify(fixture.source, candidate.base_manifest)
    refute File.exists?(Path.join(fixture.app, "priv/static"))
    refute File.exists?(Path.join(fixture.app, "_build"))
    refute File.exists?(Path.join(fixture.source, "_build"))
    assert false == :code.is_loaded(CandidateProduction.Endpoint)

    assert {:error, :invalid_execution_context} =
             Execution.verify_context(
               candidate,
               Map.put(context, "deps", Path.join(context["root"], "deps"))
             )

    for path <- [
          Path.join(context["source"], "unreviewed.txt"),
          Path.join(context["app"], "lib/unreviewed.ex")
        ] do
      write!(path, "unreviewed source bytes\n")
      assert {:error, :source_changed} = Execution.verify_context(candidate, context)
      File.rm!(path)
      assert :ok = Execution.verify_context(candidate, context)
    end
  end

  test "the configured installed esbuild fails assets.deploy on real invalid JavaScript" do
    assert :error = Application.fetch_env(:oh_my_jido_docs, :candidate_check_steps)
    tools = Application.fetch_env!(:oh_my_jido_docs, :candidate_asset_tools)
    assert {:ok, _esbuild} = Runner.available(Keyword.fetch!(tools, :esbuild))
    {run, workspace} = run_workspace()

    write!(Path.join(workspace, "assets/js/app.js"), """
    import {Socket} from "phoenix"
    window.candidatePipeline = {socket: new Socket("/socket"), icon: "hero-book-open"}
    export const broken = ;
    """)

    assert {:ok, candidate} = Candidates.prepare(run.id)
    Editor.subscribe(run.id)
    assert {:ok, _} = Candidates.start_check(candidate.id)
    deadline = System.monotonic_time(:millisecond) + 660_000

    failed =
      await(
        candidate.id,
        &(&1.check_status not in ["pending", "running", "cancelling"]),
        deadline
      )

    assert failed.check_status == "failed", failed.check_output
    steps = failed.check_receipt["steps"]
    mix_steps = Enum.reject(steps, &(&1["phase"] == "dependency_preflight"))
    assert Enum.map(mix_steps, &{&1["mix_env"], &1["args"]}) == Enum.take(@default_mix_steps, 6)
    asset_step = List.last(mix_steps)
    assert asset_step["args"] == ["assets.deploy"]
    assert asset_step["status"] == "failed"
    assert asset_step["exit_status"] != 0
    assert asset_step["effect"] == "completed"
    assert asset_step["output"] =~ "js/app.js"
    assert asset_step["output"] =~ "[ERROR]"
    assert asset_step["output"] =~ "`mix esbuild candidate_fixture --minify` exited with 1"

    context = failed.check_receipt["context"]
    environment = Execution.environment(context, "prod")
    assert environment["ESBUILD_PATH"] == Keyword.fetch!(tools, :esbuild)
    assert environment["TAILWIND_PATH"] == Keyword.fetch!(tools, :tailwind)

    assert File.read!(Path.join(context["app"], "priv/static/assets/css/app.css")) =~
             ".hero-book-open"

    refute File.exists?(Path.join(context["app"], "priv/static/assets/js/app.js"))
    refute File.exists?(Path.join(context["root"], "build/prod/rel/candidate_fixture"))
    refute Map.has_key?(failed.check_receipt, "release")
    assert {:error, :checks_required} = Candidates.approve(candidate.id, candidate.digest)
  end

  test "a missing explicitly configured asset executable is unavailable, never skipped",
       fixture do
    tools = Application.fetch_env!(:oh_my_jido_docs, :candidate_asset_tools)
    missing = Path.join(fixture.temporary, "unavailable-tailwind")
    put_setting(:candidate_asset_tools, Keyword.put(tools, :tailwind, missing))
    on_exit(&DataCase.stop_private_workers/0)
    assert {:error, {:asset_tool_unavailable, "TAILWIND_PATH"}} = Execution.check_available()
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# No installed asset tool\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)

    unavailable_callback = fn _launch ->
      flunk("an unavailable asset prerequisite must not start a child")
    end

    receipt =
      Execution.check(candidate, self(), make_ref(), %{
        before_start: unavailable_callback,
        on_start: unavailable_callback,
        on_scope: unavailable_callback
      })

    assert receipt["status"] == "unavailable"
    assert receipt["reason"] == inspect({:asset_tool_unavailable, "TAILWIND_PATH"})
    refute Map.has_key?(receipt, "context")
    refute Map.has_key?(receipt, "steps")
  end
end
