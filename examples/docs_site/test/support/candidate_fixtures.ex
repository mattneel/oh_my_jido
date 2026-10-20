defmodule OhMyJidoDocs.CandidateFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias OhMyJidoDocs.{Candidates, Content, DataCase, Editor, Repo, Workspaces}
  alias OhMyJidoDocs.Candidates.{Runner, Source}
  alias OhMyJidoDocs.Editor.Run

  # Required closure of the cached Phoenix, Bandit and Jason projects:
  # Phoenix -> Plug, PlugCrypto, Telemetry, PubSub, Template, WebSockAdapter;
  # WebSockAdapter -> WebSock + Plug; Plug -> MIME + PlugCrypto + Telemetry;
  # Bandit -> ThousandIsland + Plug + WebSock + HPAX + Telemetry;
  # ThousandIsland -> Telemetry. The remaining packages have no required deps.
  # Mix loads dependencies in :prod even when the fixture itself is in :test,
  # so their docs/dev/test-only and unselected optional dependencies stay out.
  @preview_dependencies ~w(
    phoenix bandit jason phoenix_pubsub phoenix_template websock_adapter websock
    plug plug_crypto mime telemetry thousand_island hpax
  )

  # Esbuild requires Jason (above); Tailwind has no required dependency.
  # Heroicons is the real asset-only checkout consumed by the Tailwind plugin.
  @asset_dependencies ~w(esbuild tailwind heroicons)

  def setup_fixture(temporary, opts \\ []) do
    source = Path.join(temporary, "source")
    app = Path.join(source, "examples/docs_site")
    fixture(source, app)

    settings = [
      editor_enabled: true,
      source_root: source,
      source_app_path: "examples/docs_site",
      data_dir: Path.join(temporary, "data"),
      published_root: Path.join(temporary, "published"),
      static_docs_root: Path.join(app, "priv/docs"),
      candidate_dependency_roots: [],
      candidate_native_caches: [],
      candidate_native_artifacts: %{},
      candidate_release_name: "candidate_fixture",
      candidate_max_effects: 1,
      candidate_check_timeout_ms: 180_000,
      candidate_preview_ready_timeout_ms: 30_000,
      candidate_preview_lifetime_ms: 120_000,
      flyctl: nil,
      fly_app: nil,
      fly_token: nil
    ]

    Enum.each(settings, fn {key, value} -> put_setting(key, value) end)
    assert {:ok, _digest} = Content.publish_directory(Path.join(app, "priv/docs"), nil)
    on_exit(fn -> Source.remove_tree(temporary) end)

    if Keyword.get(opts, :default_pipeline, false) do
      delete_setting(:candidate_check_steps)
      default_pipeline_fixture(source, app)
    else
      put_setting(:candidate_check_steps, [
        {"test", ["test"]},
        {"prod", ["compile", "--warnings-as-errors"]},
        {"prod", ["release", "--overwrite"]}
      ])

      if Keyword.get(opts, :phoenix, false), do: phoenix_fixture(source, app)
    end

    # Later run_workspace callbacks settle real cancellation receipts first.
    # Stop the private subtree before any earlier env/source cleanup runs.
    on_exit(&DataCase.stop_private_workers/0)

    %{source: source, app: app, temporary: temporary}
  end

  def check!(candidate, timeout_ms \\ 240_000) do
    Editor.subscribe(candidate.run_id)
    assert {:ok, _} = Candidates.start_check(candidate.id)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    result =
      await(
        candidate.id,
        &(&1.check_status not in ["pending", "running", "cancelling"]),
        deadline
      )

    assert result.check_status == "passed", result.check_output
    result
  end

  def await(id, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 240_000
    candidate = Candidates.get!(id)

    cond do
      predicate.(candidate) ->
        candidate

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("candidate effect deadline: #{inspect(candidate)}")

      true ->
        receive do
          {:docs_run_updated, _run_id} -> await(id, predicate, deadline)
        after
          100 -> await(id, predicate, deadline)
        end
    end
  end

  def run_workspace(opts \\ []) do
    id = Ecto.UUID.generate()
    assert {:ok, %{workspace: workspace, base_revision: base}} = Workspaces.create(id)

    run =
      %Run{id: id}
      |> Run.changeset(%{
        task: "Review real isolated source",
        mode: Keyword.get(opts, :mode, "coding"),
        session_id: Ecto.UUID.generate(),
        status: "completed",
        workspace: workspace,
        base_revision: base
      })
      |> Repo.insert!()

    on_exit(fn ->
      Enum.each(Candidates.list(run.id), fn candidate ->
        Candidates.cancel_check(candidate.id)
        Candidates.stop_preview(candidate.id)
        Candidates.cancel_deploy(candidate.id)

        await(candidate.id, fn current ->
          current.check_status not in ["running", "cancelling"] and
            current.preview_status not in ["starting", "running", "stopping"] and
            current.deployment_status not in ["running", "cancelling"]
        end)
      end)
    end)

    {run, workspace}
  end

  defp fixture(source, app) do
    write!(Path.join(source, "mix.exs"), """
    defmodule CandidateLibrary.MixProject do
      use Mix.Project
      def project, do: [app: :candidate_library, version: "0.1.0", elixir: ">= 1.17.0"]
      def application, do: []
    end
    """)

    write!(Path.join(source, "lib/candidate_library.ex"), """
    defmodule CandidateLibrary do
      def value, do: "root-library"
    end
    """)

    write!(Path.join(app, "mix.exs"), fixture_mix([]))
    write!(Path.join(app, "lib/authored.ex"), authored_source("root-library"))
    write!(Path.join(app, "test/test_helper.exs"), "ExUnit.start()\n")
    write!(Path.join(app, "test/authored_test.exs"), fixture_test("root-library"))
    write!(Path.join(app, "priv/docs/index.md"), "# Initial\n\nPublished source.\n")
  end

  def fixture_mix(
        dependencies,
        application \\ "[extra_applications: [:logger]]",
        aliases \\ "[]"
      ) do
    deps = ["{:candidate_library, path: \"../..\"}" | dependencies] |> Enum.join(",\n        ")

    """
    defmodule CandidateFixture.MixProject do
      use Mix.Project
      def project do
        [app: :candidate_fixture, version: "0.1.0", elixir: ">= 1.17.0",
         deps: [#{deps}], aliases: #{aliases}]
      end
      def application, do: #{application}
    end
    """
  end

  def authored_source(expected) do
    """
    defmodule CandidateOnly.Authored do
      def text, do: "#{String.trim_trailing(expected, "root-library")}" <> CandidateLibrary.value()
    end
    """
  end

  def fixture_test(expected) do
    """
    defmodule CandidateOnly.AuthoredTest do
      use ExUnit.Case
      test "uses the isolated repository library dependency" do
        assert CandidateOnly.Authored.text() == #{inspect(expected)}
      end
    end
    """
  end

  def source_dependencies!(source, names) do
    dependency_root = Path.expand("../../deps", __DIR__)

    for dependency <- names do
      path = Path.join(dependency_root, dependency)

      assert {:ok, manifest} = Source.manifest(path),
             "Required cached dependency source #{dependency} is unavailable at #{path}; fixtures never fetch dependencies"

      assert :ok = Source.copy(path, Path.join([source, "vendor", dependency]), manifest)
    end

    Enum.map(names, fn name ->
      "{:#{name}, path: \"../../vendor/#{name}\", override: true}"
    end)
  end

  def phoenix_source_fixture(%{source: source, app: app}), do: phoenix_fixture(source, app)

  def phoenix_fixture(source, app) do
    dependencies = source_dependencies!(source, @preview_dependencies)

    write!(
      Path.join(app, "mix.exs"),
      fixture_mix(
        dependencies,
        "[mod: {CandidatePreview.Application, []}, extra_applications: [:logger]]"
      )
    )

    write!(Path.join(app, "lib/preview.ex"), """
    defmodule CandidatePreview.Application do
      use Application
      def start(_type, _args) do
        Supervisor.start_link([
          {Phoenix.PubSub, name: CandidatePreview.PubSub},
          CandidatePreview.Endpoint
        ], strategy: :one_for_one)
      end
    end

    defmodule CandidatePreview.Router do
      use Plug.Router
      plug :match
      plug :dispatch

      get "/" do
        docs(conn)
      end

      get "/docs/index" do
        docs(conn)
      end

      get "/docs/headers" do
        body = Jason.encode!(%{
          cookie: get_req_header(conn, "cookie"),
          authorization: get_req_header(conn, "authorization"),
          query: conn.query_string
        })
        conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
      end

      get "/docs/redirect" do
        conn |> put_resp_header("location", "https://example.org/not-allowed") |> send_resp(302, "Moved")
      end

      get "/docs/oversized" do
        conn |> put_resp_content_type("text/html") |> send_resp(200, String.duplicate("X", 4_194_305))
      end

      get "/assets/unsafe.js" do
        conn |> put_resp_content_type("application/javascript") |> send_resp(200, "window.preview = true;")
      end

      get "/assets/preview.css" do
        body = ~s|@import '/assets/secondary.css'; body{color:#123456;background-image:url('/images/pixel.svg')}|
        conn |> put_resp_content_type("text/css") |> send_resp(200, body)
      end

      get "/assets/secondary.css" do
        conn |> put_resp_content_type("text/css") |> send_resp(200, "body{font-family:system-ui}")
      end

      get "/images/pixel.svg" do
        image = ~s|<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>|
        conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, image)
      end

      match _ do
        send_resp(conn, 404, "Not found")
      end

      defp docs(conn) do
        body = File.read!(Application.app_dir(:candidate_fixture, "priv/docs/index.md"))
        html = ~s|<!doctype html><html><head><link rel="stylesheet" href="/assets/preview.css"></head><body><main>| <>
          body <> ~s|</main><a href="/docs/index">Read documentation</a></body></html>|
        conn |> put_resp_content_type("text/html") |> send_resp(200, html)
      end
    end

    defmodule CandidatePreview.Endpoint do
      use Phoenix.Endpoint, otp_app: :candidate_fixture
      plug CandidatePreview.Router
    end
    """)

    write!(Path.join(app, "config/config.exs"), """
    import Config
    config :candidate_fixture, CandidatePreview.Endpoint,
      url: [host: "localhost"],
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: 4002],
      server: false,
      secret_key_base: String.duplicate("x", 64),
      pubsub_server: CandidatePreview.PubSub
    """)

    write!(Path.join(app, "config/runtime.exs"), """
    import Config
    if System.get_env("PHX_SERVER") do
      config :candidate_fixture, CandidatePreview.Endpoint,
        server: true,
        http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.fetch_env!("PORT"))],
        secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
    end
    """)
  end

  # Keep the ordinary Phoenix asset consumers and every default child Mix step.
  # Only trusted cached dependency sources and installed native tools are used.
  defp default_pipeline_fixture(source, app) do
    dependency_root = Path.expand("../../deps", __DIR__)

    dependencies =
      Enum.map(@preview_dependencies ++ @asset_dependencies, fn name ->
        cached = Path.join(dependency_root, name)

        assert {:ok, manifest} = Source.manifest(cached),
               "Required cached dependency source #{name} is unavailable at #{cached}; fixtures never fetch dependencies"

        assert :ok = Source.copy(cached, Path.join([app, "deps", name]), manifest)

        options =
          case name do
            "heroicons" -> ", app: false, compile: false"
            name when name in ["esbuild", "tailwind"] -> ", runtime: false"
            _name -> ""
          end

        "{:#{name}, path: \"deps/#{name}\", override: true#{options}}"
      end)

    aliases =
      inspect(
        "assets.deploy": [
          "tailwind candidate_fixture --minify",
          "esbuild candidate_fixture --minify",
          "phx.digest"
        ]
      )

    write!(
      Path.join(app, "mix.exs"),
      fixture_mix(
        dependencies,
        "[mod: {CandidateProduction.Application, []}, extra_applications: [:logger]]",
        aliases
      )
    )

    write!(Path.join(app, "lib/production.ex"), """
    defmodule CandidateProduction.Application do
      use Application

      def start(_type, _args) do
        Supervisor.start_link([
          {Phoenix.PubSub, name: CandidateProduction.PubSub},
          CandidateProduction.Endpoint
        ], strategy: :one_for_one)
      end
    end

    defmodule CandidateProduction.Router do
      use Plug.Router
      plug :match
      plug :dispatch

      get "/" do
        body = File.read!(Application.app_dir(:candidate_fixture, "priv/docs/index.md"))
        conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
      end

      match _ do
        send_resp(conn, 404, "Not found")
      end
    end

    defmodule CandidateProduction.Endpoint do
      use Phoenix.Endpoint, otp_app: :candidate_fixture
      plug Plug.Static, at: "/", from: :candidate_fixture, only: ~w(assets)
      plug CandidateProduction.Router
    end
    """)

    write!(Path.join(app, "config/config.exs"), """
    import Config

    config :candidate_fixture, CandidateProduction.Endpoint,
      url: [host: "localhost"],
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: 4002],
      server: false,
      secret_key_base: String.duplicate("x", 64),
      pubsub_server: CandidateProduction.PubSub

    config :phoenix, :json_library, Jason

    config :esbuild,
      version: #{inspect(Application.fetch_env!(:esbuild, :version))},
      candidate_fixture: [
        args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
        cd: Path.expand("../assets", __DIR__),
        env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
      ]

    config :tailwind,
      version: #{inspect(Application.fetch_env!(:tailwind, :version))},
      candidate_fixture: [
        args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
        cd: Path.expand("..", __DIR__),
        env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
      ]

    if path = System.get_env("ESBUILD_PATH"), do: config(:esbuild, path: path)
    if path = System.get_env("TAILWIND_PATH"), do: config(:tailwind, path: path)
    """)

    write!(Path.join(app, "config/runtime.exs"), """
    import Config

    if System.get_env("PHX_SERVER") do
      config :candidate_fixture, CandidateProduction.Endpoint,
        server: true,
        http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.fetch_env!("PORT"))],
        secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
    end
    """)

    write!(Path.join(app, "assets/js/app.js"), """
    import {Socket} from "phoenix"
    window.candidatePipeline = {socket: new Socket("/socket"), icon: "hero-book-open"}
    """)

    write!(Path.join(app, "assets/css/app.css"), """
    @import "tailwindcss" source(none);
    @source "../js";
    @plugin "../vendor/heroicons";
    """)

    write!(
      Path.join(app, "assets/vendor/heroicons.js"),
      File.read!(Path.expand("../../assets/vendor/heroicons.js", __DIR__))
    )

    configured_tools = Application.get_env(:oh_my_jido_docs, :candidate_asset_tools, [])

    tools =
      Enum.map([esbuild: Esbuild, tailwind: Tailwind], fn {name, module} ->
        path = Keyword.get(configured_tools, name) || module.bin_path()

        assert {:ok, executable} = Runner.available(path),
               "The default pipeline requires an installed trusted #{name} executable: #{inspect(path)}"

        {name, executable}
      end)

    put_setting(:candidate_asset_tools, tools)
    put_setting(:candidate_dependency_roots, [Path.join(app, "deps")])
    put_setting(:candidate_check_timeout_ms, 600_000)
    assert File.regular?(Path.join(source, "lib/candidate_library.ex"))
  end

  def http_get!(url) do
    port = URI.parse(url).port
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    result = read_http(socket, [])
    :gen_tcp.close(socket)
    result
  end

  defp read_http(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> read_http(socket, [chunk | chunks])
      {:error, :closed} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, reason} -> flunk("preview response failed: #{inspect(reason)}")
    end
  end

  def write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  def put_setting(key, value) do
    previous = Application.fetch_env(:oh_my_jido_docs, key)
    Application.put_env(:oh_my_jido_docs, key, value)
    on_exit(fn -> restore_setting(key, previous) end)
  end

  def delete_setting(key) do
    previous = Application.fetch_env(:oh_my_jido_docs, key)
    Application.delete_env(:oh_my_jido_docs, key)
    on_exit(fn -> restore_setting(key, previous) end)
  end

  defp restore_setting(key, {:ok, value}), do: Application.put_env(:oh_my_jido_docs, key, value)
  defp restore_setting(key, :error), do: Application.delete_env(:oh_my_jido_docs, key)
end
