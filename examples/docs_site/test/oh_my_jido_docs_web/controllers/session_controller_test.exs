defmodule OhMyJidoDocsWeb.SessionControllerTest do
  use OhMyJidoDocsWeb.ConnCase, async: false

  import OhMyJidoDocsWeb.EditorialFixtures
  import Phoenix.LiveViewTest

  alias OhMyJidoDocs.Editor

  setup do
    configure_operator()
    :ok
  end

  test "password hashes authenticate, renew the session, and never preserve unrelated session state",
       %{conn: conn} do
    conn = init_test_session(conn, %{"untrusted" => "discard-me", "operator" => "forged"})

    conn =
      post(conn, ~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    assert redirected_to(conn) == ~p"/studio"
    assert get_session(conn, "untrusted") == nil
    session = get_session(conn, "operator_session")
    assert session["username"] == "editor-test"
    assert session["expires_at"] > System.system_time(:second)
    refute inspect(get_session(conn)) =~ "private-test-password"

    refute inspect(get_session(conn)) =~
             Application.fetch_env!(:oh_my_jido_docs, :operator_password_hash)

    assert conn.private.plug_session_info == :renew
    cookie = conn.resp_cookies["_oh_my_jido_docs_key"]
    assert cookie.http_only
    assert cookie.same_site == "Lax"
    assert cookie.max_age == 28_800

    next =
      conn
      |> recycle()
      |> post(~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    refute get_session(next, "operator_session")["nonce"] == session["nonce"]
  end

  test "wrong username and wrong password do not establish an editorial session", %{conn: conn} do
    for credentials <- [
          %{username: "editor-test", password: "wrong"},
          %{username: "other", password: "private-test-password"}
        ] do
      rejected = conn |> recycle() |> post(~p"/login", login: credentials)
      assert html_response(rejected, 401)
      assert get_session(rejected, "operator_session") == nil
      assert get_resp_header(rejected, "cache-control") == ["no-store"]
    end
  end

  test "tampered signed cookie, expired sessions, and password rotation reject HTTP and LiveView",
       %{conn: conn} do
    login =
      post(conn, ~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    cookie = login.resp_cookies["_oh_my_jido_docs_key"].value

    tampered =
      build_conn()
      |> Plug.Test.put_req_cookie("_oh_my_jido_docs_key", cookie <> "tampered")
      |> get(~p"/studio")

    assert redirected_to(tampered) == ~p"/login"

    expired =
      Map.put(
        get_session(login, "operator_session"),
        "expires_at",
        System.system_time(:second) - 1
      )

    expired_conn = build_conn() |> init_test_session(%{"operator_session" => expired})
    assert {:error, {:redirect, %{to: "/login"}}} = live(expired_conn, ~p"/studio")

    Application.put_env(
      :oh_my_jido_docs,
      :operator_password_hash,
      Pbkdf2.hash_pwd_salt("replacement-password", rounds: 4)
    )

    rotated = login |> recycle() |> get(~p"/studio")
    assert redirected_to(rotated) == ~p"/login"
    assert {:error, {:redirect, %{to: "/login"}}} = live(recycle(login), ~p"/studio")
  end

  test "logout clears the session, disconnects live editorial sockets, and rejects subsequent access",
       %{conn: conn} do
    login =
      post(conn, ~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    socket_topic = get_session(login, "live_socket_id")
    OhMyJidoDocsWeb.Endpoint.subscribe(socket_topic)
    signed_out = login |> recycle() |> delete(~p"/logout")
    assert redirected_to(signed_out) == ~p"/login"
    assert get_session(signed_out, "operator_session") == nil
    assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_topic, event: "disconnect"}
    assert signed_out |> recycle() |> get(~p"/studio") |> redirected_to() == ~p"/login"
  end

  test "anonymous visitors cannot load a run, candidate review, preview, or LiveView", %{
    conn: conn
  } do
    run = stored_run(%{task: "Confidential editorial instruction"})
    candidate = Ecto.UUID.generate()

    for path <- [
          ~p"/studio",
          ~p"/studio/runs/#{run.id}",
          ~p"/studio/runs/#{run.id}/candidates/#{candidate}"
        ] do
      response = conn |> recycle() |> get(path)
      assert redirected_to(response) == ~p"/login"
      refute response.resp_body =~ run.task
    end

    preview = conn |> recycle() |> get(~p"/studio/previews/#{candidate}/")
    assert response(preview, 403)
    refute preview.resp_body =~ run.task

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/studio/runs/#{run.id}")
    assert Editor.get_run!(run.id).status == "completed"
  end

  test "unconfigured credentials and the public-only deployment fail closed", %{conn: conn} do
    Application.delete_env(:oh_my_jido_docs, :operator_password_hash)
    assert conn |> get(~p"/login") |> html_response(503)

    denied =
      conn
      |> recycle()
      |> post(~p"/login", login: %{username: "editor-test", password: "private-test-password"})

    assert denied.status == 503
    assert get_session(denied, "operator_session") == nil

    Application.put_env(:oh_my_jido_docs, :editor_enabled, false)

    for path <- [
          ~p"/login",
          ~p"/studio",
          ~p"/studio/runs/#{Ecto.UUID.generate()}",
          ~p"/studio/previews/#{Ecto.UUID.generate()}/"
        ] do
      assert conn |> recycle() |> get(path) |> response(404)
    end

    assert conn
           |> recycle()
           |> post(~p"/login",
             login: %{username: "editor-test", password: "private-test-password"}
           )
           |> response(404)
  end

  test "login rejects forged browser writes without a CSRF token", %{conn: conn} do
    assert_error_sent 403, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/login", login: %{username: "editor-test", password: "private-test-password"})
    end

    assert Editor.list_runs() == []
  end
end
