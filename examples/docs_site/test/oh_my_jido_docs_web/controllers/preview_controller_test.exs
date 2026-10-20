defmodule OhMyJidoDocsWeb.PreviewControllerTest do
  use OhMyJidoDocsWeb.ConnCase, async: false

  import OhMyJidoDocsWeb.EditorialFixtures, only: [configure_operator: 0]
  import OhMyJidoDocs.CandidateFixtures
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias OhMyJidoDocs.Candidates
  alias OhMyJidoDocsWeb.{Endpoint, PreviewCapability}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000
  @salt "docs-public-preview-v1"

  setup %{tmp_dir: temporary} = context do
    configure_operator()
    fixture = setup_fixture(temporary, phoenix: context[:real_preview] == true)
    {run, workspace} = run_workspace()

    write!(
      Path.join(workspace, "priv/docs/index.md"),
      "# Verified preview\n\nReviewed source bytes.\n"
    )

    {:ok, candidate} = Candidates.prepare(run.id)
    Map.merge(fixture, %{candidate: candidate, run: run})
  end

  @tag real_preview: true
  @tag :candidate_integration
  test "an owned preview supports cookieless sandbox HTML, styles, images and navigation with scoped capabilities",
       %{conn: conn, candidate: candidate} do
    candidate = check!(candidate)
    assert {:ok, _} = Candidates.start_preview(candidate.id)
    running = await(candidate.id, &(&1.preview_status == "running"))
    assert {:ok, target} = Candidates.preview_target(candidate.id)
    assert target.attempt_id == running.preview_receipt["attempt_id"]

    on_exit(fn -> stop_preview(candidate.id) end)

    login =
      post(conn, ~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    session = get_session(login, "operator_session")

    {:ok, view, html} =
      live(recycle(login), ~p"/studio/runs/#{candidate.run_id}/candidates/#{candidate.id}")

    frame = html |> LazyHTML.from_document() |> LazyHTML.query("#candidate-preview")
    assert LazyHTML.attribute(frame, "sandbox") == [""]
    assert LazyHTML.attribute(frame, "referrerpolicy") == ["no-referrer"]
    [src] = LazyHTML.attribute(frame, "src")
    token = token_from(src)
    assert {:ok, claims} = Phoenix.Token.verify(Endpoint, @salt, token, max_age: 300)
    assert claims["candidate_id"] == candidate.id
    assert claims["digest"] == candidate.digest
    assert claims["attempt_id"] == target.attempt_id
    assert claims["session_nonce"] == session["nonce"]
    assert claims["session_expires_at"] == session["expires_at"]
    assert claims["expires_at"] <= session["expires_at"]
    assert claims["expires_at"] <= System.system_time(:second) + 300
    GenServer.stop(view.pid)

    # A fresh connection has no operator cookie, matching an opaque sandbox's
    # resource and navigation requests. Only the scoped capability authorizes it.
    preview = get(build_conn(), src)
    body = html_response(preview, 200)
    request_log = capture_log(fn -> assert build_conn() |> get(src) |> response(200) end)
    refute request_log =~ token
    [csp] = get_resp_header(preview, "content-security-policy")
    assert csp =~ "sandbox;"
    assert csp =~ "script-src 'none'"
    assert csp =~ "connect-src 'none'"
    assert csp =~ "form-action 'none'"
    refute csp =~ "allow-same-origin"
    assert get_resp_header(preview, "cache-control") == ["no-store"]
    assert get_resp_header(preview, "referrer-policy") == ["no-referrer"]
    refute Map.has_key?(preview.resp_cookies, "preview_injected")

    document = LazyHTML.from_document(body)
    [css_url] = document |> LazyHTML.query("link[rel=stylesheet]") |> LazyHTML.attribute("href")

    [next_url] =
      document |> LazyHTML.query("a[href*='/docs/index']") |> LazyHTML.attribute("href")

    assert token_from(css_url) == token
    assert token_from(next_url) == token
    css = build_conn() |> put_req_header("accept", "text/css") |> get(css_url) |> response(200)
    [[_, import_url]] = Regex.scan(~r/@import\s+"([^"]+)"/, css)
    [[_, image_url]] = Regex.scan(~r/url\("([^"]+)"\)/, css)
    assert token_from(import_url) == token
    assert token_from(image_url) == token
    assert build_conn() |> get(import_url) |> response(200)
    assert build_conn() |> get(image_url) |> response(200)
    assert build_conn() |> get(next_url) |> html_response(200) =~ "Verified preview"

    captured =
      build_conn()
      |> Plug.Test.put_req_cookie("editor_private", "must-not-forward")
      |> put_req_header("authorization", "Bearer must-not-forward")
      |> get(PreviewCapability.path(candidate.id, ["docs", "headers"], token))
      |> response(200)
      |> Jason.decode!()

    assert captured == %{"cookie" => [], "authorization" => [], "query" => ""}

    # These are real responses from the owned child, not manufactured ready rows.
    assert build_conn()
           |> get(PreviewCapability.path(candidate.id, ["docs", "redirect"], token))
           |> response(502)

    assert build_conn()
           |> get(PreviewCapability.path(candidate.id, ["assets", "unsafe.js"], token))
           |> response(415)

    assert build_conn()
           |> get(PreviewCapability.path(candidate.id, ["docs", "oversized"], token))
           |> response(502)

    for path <- [
          "studio",
          "login",
          "assets/%2e%2e%2fstudio",
          "docs/%2e%2e",
          "assets/%252e%252e/private"
        ] do
      url =
        "/studio/previews/#{candidate.id}/#{path}?" <>
          URI.encode_query(%{"preview_token" => token})

      assert build_conn() |> get(url) |> response(404)
    end

    assert build_conn() |> get("/studio/previews/#{candidate.id}/") |> response(403)
    assert build_conn() |> head(src) |> response(405)
    assert build_conn() |> post(src, %{"_method" => "get"}) |> response(404)

    assert build_conn()
           |> get(PreviewCapability.path(candidate.id, [], token <> "tampered"))
           |> response(403)

    assert build_conn()
           |> get(PreviewCapability.path(Ecto.UUID.generate(), [], token))
           |> response(403)

    assert build_conn()
           |> get(resign(src, &Map.put(&1, "expires_at", System.system_time(:second) - 1)))
           |> response(403)

    assert build_conn()
           |> get(
             resign(src, &Map.put(&1, "session_expires_at", System.system_time(:second) - 1))
           )
           |> response(403)

    assert build_conn()
           |> get(resign(src, &Map.put(&1, "scope", "editorial-mutation")))
           |> response(403)

    assert build_conn()
           |> get(resign(src, &Map.put(&1, "attempt_id", Ecto.UUID.generate())))
           |> response(409)

    assert build_conn()
           |> get(resign(src, &Map.put(&1, "digest", String.duplicate("f", 64))))
           |> response(409)

    original_hash = Application.fetch_env!(:oh_my_jido_docs, :operator_password_hash)

    Application.put_env(
      :oh_my_jido_docs,
      :operator_password_hash,
      Pbkdf2.hash_pwd_salt("rotated-preview-password", rounds: 4)
    )

    assert build_conn() |> get(src) |> response(403)
    Application.put_env(:oh_my_jido_docs, :operator_password_hash, original_hash)
    Application.put_env(:oh_my_jido_docs, :editor_enabled, false)
    assert build_conn() |> get(src) |> response(404)
    Application.put_env(:oh_my_jido_docs, :editor_enabled, true)

    stop_preview(candidate.id)
    assert build_conn() |> get(src) |> response(409)
    assert {:ok, _} = Candidates.start_preview(candidate.id)
    await(candidate.id, &(&1.preview_status == "running"))
    assert {:ok, replacement} = Candidates.preview_target(candidate.id)
    refute replacement.attempt_id == target.attempt_id
    assert build_conn() |> get(src) |> response(409)
    assert {:ok, replacement_src} = PreviewCapability.url_for_candidate(candidate.id, session)
    assert build_conn() |> get(replacement_src) |> html_response(200) =~ "Verified preview"
  end

  test "a counterfeit ready row and unrelated loopback listener cannot issue or satisfy preview access",
       %{conn: conn, candidate: candidate} do
    {url, request_ref} = unrelated_listener()
    # This row is deliberately counterfeit; no managed preview was launched.
    # Undo the fixture forgery before ordinary managed-effect teardown runs.
    original_preview = Map.take(candidate, [:preview_url, :preview_status])

    on_exit(fn ->
      {:ok, _} = Candidates.update(Candidates.get!(candidate.id), original_preview)
    end)

    assert {:ok, _} = Candidates.update(candidate, %{preview_url: url, preview_status: "running"})

    login =
      post(conn, ~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    session = get_session(login, "operator_session")
    assert {:error, _reason} = PreviewCapability.url_for_candidate(candidate.id, session)
    assert {:error, _reason} = Candidates.preview_target(candidate.id)

    {:ok, view, html} =
      live(recycle(login), ~p"/studio/runs/#{candidate.run_id}/candidates/#{candidate.id}")

    assert has_element?(view, "#preview-unavailable")
    assert Enum.empty?(html |> LazyHTML.from_document() |> LazyHTML.query("#candidate-preview"))
    GenServer.stop(view.pid)

    claims = %{
      "scope" => "public-preview",
      "method" => "GET",
      "candidate_id" => candidate.id,
      "digest" => candidate.digest,
      "attempt_id" => Ecto.UUID.generate(),
      "credential_version" => session["version"],
      "session_nonce" => session["nonce"],
      "session_expires_at" => session["expires_at"],
      "expires_at" => System.system_time(:second) + 300
    }

    token = Phoenix.Token.sign(Endpoint, @salt, claims)
    assert build_conn() |> get(PreviewCapability.path(candidate.id, [], token)) |> response(409)

    for target <- [
          "https://example.invalid/",
          "http://localhost:4000/",
          "http://127.0.0.1:4000/studio",
          "http://user:secret@127.0.0.1:4000/"
        ] do
      assert {:ok, _} =
               Candidates.update(Candidates.get!(candidate.id), %{
                 preview_url: target,
                 preview_status: "running"
               })

      assert build_conn() |> get(PreviewCapability.path(candidate.id, [], token)) |> response(409)
    end

    refute_receive {:unrelated_preview_request, ^request_ref}, 100
  end

  defp token_from(url),
    do:
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("preview_token")

  defp resign(url, update) do
    uri = URI.parse(url)
    {:ok, claims} = Phoenix.Token.verify(Endpoint, @salt, token_from(url), max_age: 300)
    token = Phoenix.Token.sign(Endpoint, @salt, update.(claims))
    URI.to_string(%{uri | query: URI.encode_query(%{"preview_token" => token})})
  end

  defp stop_preview(id) do
    case Candidates.stop_preview(id) do
      {:ok, _} ->
        stopped = await(id, &(&1.preview_status not in ["starting", "running", "stopping"]))
        assert stopped.preview_status == "stopped"
        assert get_in(stopped.preview_receipt, ["process", "cleanup", "status"]) == "confirmed"
        stopped

      {:error, :not_running} ->
        :ok

      {:error, reason} ->
        flunk("Owned preview cleanup failed: #{inspect(reason)}")
    end
  end

  defp unrelated_listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    parent = self()
    request_ref = make_ref()

    pid =
      spawn(fn ->
        case :gen_tcp.accept(listener, 10_000) do
          {:ok, socket} ->
            :gen_tcp.recv(socket, 0, 1000)
            send(parent, {:unrelated_preview_request, request_ref})

            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 9\r\nConnection: close\r\n\r\nUnrelated"
            )

            :gen_tcp.close(socket)

          {:error, _reason} ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {"http://127.0.0.1:#{port}/", request_ref}
  end
end
