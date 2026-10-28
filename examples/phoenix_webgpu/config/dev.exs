import Config

# WebLLM caches model weights per browser origin, so serving on the port a
# browser already used for WebLLM (for example PORT=4010) avoids downloading
# the weights again.
port = String.to_integer(System.get_env("PORT", "4000"))

config :phoenix_webgpu, PhoenixWebGPUWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  check_origin: ["//localhost:#{port}", "//127.0.0.1:#{port}"]

# Model output streams back as one LiveView event per token; debug logging
# would print every one of them.
config :logger, level: :info
