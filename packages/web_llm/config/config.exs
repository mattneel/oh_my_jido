import Config

config :req_llm, load_dotenv: false

if config_env() == :test do
  config :logger, level: :warning
  config :phoenix, :json_library, Jason

  config :web_llm, WebLLMTest.Endpoint,
    secret_key_base: String.duplicate("web_llm_test_secret_", 4),
    live_view: [signing_salt: "web_llm_test"],
    render_errors: [formats: [html: WebLLMTest.ErrorHTML], layout: false],
    pubsub_server: WebLLMTest.PubSub,
    server: false
end
