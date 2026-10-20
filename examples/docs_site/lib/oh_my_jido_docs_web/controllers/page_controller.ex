defmodule OhMyJidoDocsWeb.PageController do
  use OhMyJidoDocsWeb, :controller

  alias OhMyJidoDocs.Content

  def index(conn, _params) do
    render(conn, :index, pages: Content.list_pages(), page_title: "Documentation")
  end

  def show(conn, %{"slug" => segments}) do
    case Content.get_page(Enum.join(segments, "/")) do
      {:ok, page} ->
        render(conn, :show,
          page: page,
          pages: Content.list_pages(),
          page_title: page.title
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:not_found, pages: Content.list_pages(), page_title: "Page not found")
    end
  end
end
