defmodule PhoenixWebGPUWeb.Endpoint do
  @moduledoc "HTTP, native ES modules and the LiveView socket."
  use Phoenix.Endpoint, otp_app: :phoenix_webgpu

  @session_options [
    store: :cookie,
    key: "_phoenix_webgpu",
    signing_salt: "webgpu-session",
    same_site: "Lax",
    http_only: true
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/deps/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/deps/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Static, at: "/deps/web_llm", from: {:web_llm, "priv/static"}
  plug Plug.Static, at: "/", from: :phoenix_webgpu, only: ~w(app.js app.css)
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PhoenixWebGPUWeb.Router
end
