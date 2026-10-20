defmodule OhMyJidoDocsWeb.SessionController do
  use OhMyJidoDocsWeb, :controller

  alias OhMyJidoDocsWeb.OperatorAuth

  plug :private_response

  def new(conn, _params) do
    if conn.assigns.operator do
      redirect(conn, to: ~p"/studio")
    else
      render_login(conn)
    end
  end

  def create(conn, %{"login" => params}) when is_map(params) do
    case OperatorAuth.authenticate(params["username"], params["password"]) do
      {:ok, username} ->
        conn
        |> OperatorAuth.log_in(username)
        |> redirect(to: ~p"/studio")

      :error ->
        conn
        |> put_status(:unauthorized)
        |> render_login("The username or password is incorrect.")
    end
  end

  def create(conn, _params) do
    conn |> put_status(:unauthorized) |> render_login("The username or password is incorrect.")
  end

  def delete(conn, _params) do
    conn
    |> OperatorAuth.log_out()
    |> redirect(to: ~p"/login")
  end

  defp render_login(conn, error \\ nil) do
    configured? = OperatorAuth.configured?()
    conn = if configured?, do: conn, else: put_status(conn, :service_unavailable)

    render(conn, :new,
      form: Phoenix.Component.to_form(%{"username" => ""}, as: :login),
      configured?: configured?,
      error: error,
      page_title: "Editorial sign in"
    )
  end

  defp private_response(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end
end
