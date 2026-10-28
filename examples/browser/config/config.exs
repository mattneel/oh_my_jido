import Config

config :logger, level: :info

# Keep module attributes in the bundle: ReqLLM and Jido read `behaviour`
# attributes at runtime, and Popcorn's default stripping removes them.
config :popcorn, strip: false

# The browser VM has no sockets: stream model responses through fetch().
# Local WebLLM models are not in the model catalog; that is expected.
config :req_llm,
  load_dotenv: false,
  warn_unverified_models: false,
  finch_stream_adapter: WebLLM.Popcorn.FetchStream

config :web_llm, transport: WebLLM.Popcorn.FetchStream

# Only the end-to-end test build scripts the model.
if config_env() == :e2e do
  config :oh_my_jido_browser, fixture: OhMyJidoBrowser.Fixture
end
