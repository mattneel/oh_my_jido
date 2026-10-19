defmodule ElixosHost.CandidateTest do
  use ExUnit.Case, async: false

  alias ElixosHost.Fixtures

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: root} do
    # Production host startup prepares the same existing native model catalog.
    LLMDB.providers()

    priv = Path.join(root, "priv")
    previous = Application.fetch_env(:elixos, :priv_dir)
    Application.put_env(:elixos, :priv_dir, priv)
    on_exit(fn -> Fixtures.restore_env(:priv_dir, previous) end)
    start_supervised!({Elixos.Ask, []})
    start_supervised!({Task.Supervisor, name: ElixosHost.ApprovalTasks})
    {:ok, []} = Elixos.Ask.subscribe()
    source = Fixtures.candidate_source(root)

    options = [
      build_options: [
        target: :host,
        system_source: source,
        tool_tests: ["test/tools/**/*_test.exs"],
        timeout: 45_000
      ],
      parent_generation: 0,
      approval_timeout_ms: 5_000
    ]

    scoped = Fixtures.context(source, host_opts: options)
    %{root: root, priv: priv, source: source, options: options, scoped: scoped}
  end

  test "actual JSON child builds and suites retain evidence without loading authored modules",
       context do
    cwd = File.cwd!()
    env = System.get_env()
    refute :code.is_loaded(ElixosHost.AuthoredSentinel)

    build =
      Task.async(fn ->
        ElixosHost.Candidate.invoke(
          context.scoped,
          %{operation: :build, path: "."},
          context.options
        )
      end)

    id = Fixtures.question_id()
    assert :ok = Elixos.Ask.answer(id, true)
    assert {:ok, %{candidate_id: candidate_id}} = Task.await(build, 60_000)
    refute :code.is_loaded(ElixosHost.AuthoredSentinel)
    assert :code.which(ElixosHost.AuthoredSentinel) == :non_existing
    assert {:ok, candidate} = Elixos.Candidate.open(candidate_id)

    assert candidate.manifest.provenance.session == %{
             runtime: context.scoped.runtime,
             id: context.scoped.session_id
           }

    assert candidate.manifest.provenance.model == "anthropic:claude-sonnet-4-20250514"
    assert candidate.manifest.provenance.tools["read"].implementation == :elixir
    assert byte_size(candidate.manifest.provenance.tools["read"].revision) == 64

    assert {:ok, %{runtime: %{os_pid: pid, node: "nonode@nohost"}}} =
             Elixos.Candidate.evidence(candidate, :build)

    assert pid != System.pid()

    validation =
      Task.async(fn ->
        ElixosHost.Candidate.invoke(
          context.scoped,
          %{operation: :test, candidate_id: candidate_id},
          context.options
        )
      end)

    id = Fixtures.question_id()
    assert :ok = Elixos.Ask.answer(id, true)
    assert {:ok, %{validated: true, receipt: receipt}} = Task.await(validation, 60_000)
    assert receipt.suites.system_suite.total >= 2
    assert receipt.suites.toolset_smoke.total >= 1
    assert receipt.suites.system_suite.os_pid != System.pid()
    assert receipt.suites.toolset_smoke.os_pid != receipt.suites.system_suite.os_pid
    assert receipt.suites.system_suite.node == "nonode@nohost"
    refute :code.is_loaded(ElixosHost.AuthoredSentinel)
    refute Application.get_env(:elixos, :authored_in_host, false)
    assert File.cwd!() == cwd
    assert System.get_env() == env
    assert File.regular?(Path.join(candidate.evidence_dir, "request.json"))
    assert File.regular?(Path.join(candidate.evidence_dir, "receipt.json"))

    other = %{context.scoped | session_id: "another-session"}

    assert ElixosHost.Candidate.invoke(
             other,
             %{operation: :evidence, candidate_id: candidate_id, phase: :test},
             context.options
           ) ==
             {:error, :candidate_owner_mismatch}

    assert ElixosHost.Candidate.invoke(
             context.scoped,
             %{operation: :propose, candidate_id: candidate_id},
             context.options
           ) == {:error, :deployment_disabled}

    assert {:ok, %{result: :ok}} = Elixos.Candidate.evidence(candidate, :test)
    enabled = Keyword.put(context.options, :deployment_enabled, true)
    scoped = %{context.scoped | host: {ElixosHost.Host, enabled}}

    proposal =
      Task.async(fn ->
        ElixosHost.Candidate.invoke(
          scoped,
          %{operation: :propose, candidate_id: candidate_id},
          enabled
        )
      end)

    id = Fixtures.question_id()
    assert Task.yield(proposal, 0) == nil
    assert :ok = Elixos.Ask.dismiss(id)
    assert Task.await(proposal) == {:error, :dismissed}
    refute File.exists?(Path.join(context.priv, "generations"))
  end

  test "failed authored behavior fails both real child suites and the host health receipt",
       context do
    File.write!(Path.join(context.source, "lib/sentinel.ex"), """
    defmodule ElixosHost.AuthoredSentinel do
      def increment(value), do: value - 1
    end
    """)

    build =
      Task.async(fn ->
        ElixosHost.Candidate.invoke(
          context.scoped,
          %{operation: :build, path: "."},
          context.options
        )
      end)

    :ok = Elixos.Ask.answer(Fixtures.question_id(), true)
    assert {:ok, %{candidate_id: candidate_id}} = Task.await(build, 60_000)

    validation =
      Task.async(fn ->
        ElixosHost.Candidate.invoke(
          context.scoped,
          %{operation: :test, candidate_id: candidate_id},
          context.options
        )
      end)

    :ok = Elixos.Ask.answer(Fixtures.question_id(), true)
    assert {:error, failures} = Task.await(validation, 60_000)
    assert Keyword.has_key?(failures, :system_suite)
    assert Keyword.has_key?(failures, :toolset_smoke)
    {:ok, candidate} = Elixos.Candidate.open(candidate_id)

    assert {:error, [candidate_suite: _]} =
             Elixos.Health.run(
               [candidate_suite: fn -> Elixos.Candidate.test(candidate) end],
               generation: 0
             )

    assert File.regular?(Path.join(context.priv, "evidence/0/health.term"))
    assert {:error, :not_validated} = Elixos.Candidate.propose(candidate)
    refute :code.is_loaded(ElixosHost.AuthoredSentinel)
  end

  test "approval dismissal prevents even child compilation and evidence creation", context do
    build =
      Task.async(fn ->
        ElixosHost.Candidate.invoke(
          context.scoped,
          %{operation: :build, path: "."},
          context.options
        )
      end)

    :ok = Elixos.Ask.dismiss(Fixtures.question_id())
    assert Task.await(build) == {:error, :dismissed}
    refute File.exists?(Path.join(context.priv, "evidence/candidates"))
    refute :code.is_loaded(ElixosHost.AuthoredSentinel)
  end
end
