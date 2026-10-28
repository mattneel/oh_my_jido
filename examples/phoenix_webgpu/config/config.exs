import Config

config :phoenix_webgpu,
  scripted: false,
  parent_model: "openrouter:openai/gpt-6-luna",
  web_llm_module_url: "https://esm.run/@mlc-ai/web-llm@0.2.86"

config :phoenix_webgpu, PhoenixWebGPUWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: PhoenixWebGPUWeb.ErrorHTML], layout: false],
  pubsub_server: PhoenixWebGPU.PubSub,
  live_view: [signing_salt: "webgpu-live"]

config :phoenix, :json_library, Jason
config :req_llm, debug: false, load_dotenv: false

import_config "#{config_env()}.exs"
