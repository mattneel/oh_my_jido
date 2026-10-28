import Config

config :phoenix_webgpu, :scripted, true

config :phoenix_webgpu, PhoenixWebGPUWeb.Endpoint,
  server: false,
  check_origin: false

config :logger, level: :warning
