defmodule OhMyJidoDocsWeb.Router do
  use OhMyJidoDocsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OhMyJidoDocsWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
          "img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-src 'self'; " <>
          "object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'",
      "referrer-policy" => "no-referrer"
    }

    plug OhMyJidoDocsWeb.OperatorAuth, :fetch_operator
  end

  pipeline :preview do
    plug :fetch_query_params
    plug OhMyJidoDocsWeb.PreviewCapability
  end

  pipeline :editor_enabled do
    plug OhMyJidoDocsWeb.OperatorAuth, :require_editor
  end

  pipeline :operator do
    plug OhMyJidoDocsWeb.OperatorAuth, :require_operator
  end

  scope "/", OhMyJidoDocsWeb do
    pipe_through :browser

    get "/", PageController, :index
    get "/docs/*slug", PageController, :show
  end

  scope "/", OhMyJidoDocsWeb do
    pipe_through [:browser, :editor_enabled]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  scope "/studio", OhMyJidoDocsWeb do
    pipe_through [:browser, :editor_enabled, :operator]

    live_session :editorial,
      on_mount: [{OhMyJidoDocsWeb.OperatorAuth, :require_operator}] do
      live "/", StudioLive, :index
      live "/runs/:id", StudioLive, :show
      live "/runs/:id/candidates/:candidate_id", StudioLive, :review
    end
  end

  scope "/studio/previews", OhMyJidoDocsWeb do
    pipe_through [:editor_enabled, :preview]
    get "/:id", PreviewController, :show, log: false
    get "/:id/*path", PreviewController, :show, log: false
  end
end
