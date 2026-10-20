defmodule OhMyJidoDocs.Candidates.GitDependenciesTest do
  use OhMyJidoDocs.DataCase, async: false

  import OhMyJidoDocs.CandidateFixtures

  alias OhMyJidoDocs.{Candidates, Editor}
  alias OhMyJidoDocs.Candidates.Source

  @moduletag :candidate_integration
  @moduletag :tmp_dir

  setup %{tmp_dir: temporary} do
    fixture = setup_fixture(temporary)
    dependency = Path.join(fixture.app, "deps/offline_git_fixture")
    origin = "https://example.invalid/offline-git-fixture.git"

    write!(Path.join(dependency, "mix.exs"), """
    defmodule OfflineGitFixture.MixProject do
      use Mix.Project
      def project, do: [app: :offline_git_fixture, version: "0.1.0"]
      def application, do: []
    end
    """)

    write!(Path.join(dependency, "lib/runtime/offline_git_fixture.ex"), """
    defmodule OfflineGitFixture do
      def value, do: :locked_offline_source
    end
    """)

    assert :ok = Source.initialize_git(dependency)
    assert {:ok, _, 0} = Source.git(dependency, ["config", "remote.origin.url", origin])
    assert {:ok, revision, 0} = Source.git(dependency, ["rev-parse", "HEAD"])
    revision = String.trim(revision)

    write!(
      Path.join(fixture.app, "mix.exs"),
      fixture_mix([
        "{:offline_git_fixture, git: #{inspect(origin)}, ref: #{inspect(revision)}}"
      ])
    )

    lock = %{offline_git_fixture: {:git, origin, revision, [ref: revision]}}
    write!(Path.join(fixture.app, "mix.lock"), inspect(lock))

    write!(Path.join(fixture.app, "test/git_consumer_test.exs"), """
    defmodule OfflineGitConsumerTest do
      use ExUnit.Case
      test "uses the locked dependency implementation" do
        assert OfflineGitFixture.value() == :locked_offline_source
      end
    end
    """)

    put_setting(:candidate_dependency_roots, [Path.join(fixture.app, "deps")])
    {:ok, Map.merge(fixture, %{dependency: dependency})}
  end

  test "the isolated compiler accepts a genuinely locked offline Git dependency" do
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Locked Git consumer\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    checked = check!(candidate)
    assert Enum.all?(checked.check_receipt["steps"], &(&1["exit_status"] == 0))
    assert false == :code.is_loaded(OfflineGitFixture)
  end

  test "matching Git bytes cannot substitute for the actual locked origin", fixture do
    assert {:ok, _, 0} =
             Source.git(fixture.dependency, [
               "config",
               "remote.origin.url",
               "https://example.invalid/a-different-repository.git"
             ])

    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Reject substituted origin\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    Editor.subscribe(run.id)
    assert {:ok, _} = Candidates.start_check(candidate.id)
    failed = await(candidate.id, &(&1.check_status not in ["pending", "running", "cancelling"]))
    assert failed.check_status == "failed"
    assert failed.check_output =~ "lock mismatch"
    assert false == :code.is_loaded(OfflineGitFixture)
  end
end
