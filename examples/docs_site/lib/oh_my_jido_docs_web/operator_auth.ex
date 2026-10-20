defmodule OhMyJidoDocsWeb.OperatorAuth do
  @moduledoc """
  Single-operator, hash-backed editorial sessions. Credential rotation invalidates
  existing sessions; neither credentials nor provider configuration enter cookies.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias OhMyJidoDocsWeb.Endpoint

  @session_key "operator_session"
  @session_seconds 8 * 60 * 60

  def init(action), do: action

  def call(conn, :require_editor) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    if editor_enabled?(), do: conn, else: conn |> send_resp(404, "Not found") |> halt()
  end

  def call(conn, :fetch_operator) do
    assign(conn, :operator, operator(get_session(conn, @session_key)))
  end

  def call(conn, :require_operator) do
    if conn.assigns[:operator] do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
    else
      conn
      |> put_flash(:error, "Sign in to open the editorial workspace.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  def editor_enabled?, do: Application.get_env(:oh_my_jido_docs, :editor_enabled, false)

  def configured? do
    case {editor_enabled?(), credentials()} do
      {true, {username, hash}} when is_binary(username) and is_binary(hash) ->
        username != "" and String.starts_with?(hash, "$pbkdf2-")

      _ ->
        false
    end
  end

  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    case {configured?(), credentials()} do
      {true, {expected, hash}} ->
        password_valid? = Pbkdf2.verify_pass(password, hash)

        if password_valid? and secure_equal?(username, expected),
          do: {:ok, expected},
          else: :error

      _ ->
        Pbkdf2.no_user_verify()
        :error
    end
  rescue
    _error in [ArgumentError, MatchError, FunctionClauseError] -> :error
  end

  def authenticate(_, _) do
    Pbkdf2.no_user_verify()
    :error
  end

  def log_in(conn, username) do
    session = %{
      "username" => username,
      "version" => credential_version(),
      "expires_at" => System.system_time(:second) + @session_seconds,
      "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    }

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> delete_csrf_token()
    |> put_session(@session_key, session)
    |> put_session("live_socket_id", socket_id(session))
  end

  def log_out(conn) do
    if id = get_session(conn, "live_socket_id"), do: Endpoint.broadcast(id, "disconnect", %{})

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> delete_csrf_token()
  end

  def on_mount(:require_operator, _params, session, socket) do
    case operator(session[@session_key]) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}

      username ->
        socket =
          socket
          |> Phoenix.Component.assign(:operator, username)
          |> Phoenix.Component.assign(:operator_session, session[@session_key])
          |> Phoenix.LiveView.attach_hook(:operator_authority, :handle_event, fn _event,
                                                                                 _params,
                                                                                 socket ->
            authorize_socket(socket)
          end)
          |> Phoenix.LiveView.attach_hook(:operator_route_authority, :handle_params, fn _params,
                                                                                        _uri,
                                                                                        socket ->
            authorize_socket(socket)
          end)
          |> Phoenix.LiveView.attach_hook(:operator_async_authority, :handle_async, fn _name,
                                                                                       _result,
                                                                                       socket ->
            authorize_socket(socket)
          end)
          |> Phoenix.LiveView.attach_hook(
            :operator_session_lifetime,
            :handle_info,
            &authorize_message/2
          )

        if Phoenix.LiveView.connected?(socket) do
          remaining = session[@session_key]["expires_at"] - System.system_time(:second)
          Process.send_after(self(), :operator_session_expired, max(remaining, 1) * 1000)
        end

        {:cont, socket}
    end
  end

  defp authorize_message(message, socket) do
    case {message, authorize_socket(socket)} do
      {:operator_session_expired, {:cont, socket}} -> {:halt, socket}
      {_message, result} -> result
    end
  end

  defp authorize_socket(socket) do
    if operator(socket.assigns.operator_session) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def valid_session?(session), do: not is_nil(operator(session))

  def current_credential_version?(version) do
    configured?() and secure_equal?(version, credential_version())
  end

  defp operator(%{
         "username" => username,
         "version" => version,
         "expires_at" => expires_at,
         "nonce" => nonce
       })
       when is_binary(username) and is_binary(version) and is_integer(expires_at) and
              is_binary(nonce) and byte_size(nonce) >= 24 do
    {expected, _hash} = credentials()

    if configured?() and expires_at > System.system_time(:second) and
         secure_equal?(username, expected) and secure_equal?(version, credential_version()) do
      username
    end
  end

  defp operator(_), do: nil

  defp credentials do
    {Application.get_env(:oh_my_jido_docs, :operator_username),
     Application.get_env(:oh_my_jido_docs, :operator_password_hash)}
  end

  defp credential_version do
    credentials()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))
  end

  defp secure_equal?(_, _), do: false
  defp socket_id(session), do: "operator_sessions:" <> session["nonce"]

  defp delete_csrf_token(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    delete_session(conn, "_csrf_token")
  end
end
