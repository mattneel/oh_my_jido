# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :oh_my_jido_docs,
  ecto_repos: [OhMyJidoDocs.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :req_llm, debug: false, load_dotenv: false

# Configure the endpoint
config :oh_my_jido_docs, OhMyJidoDocsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OhMyJidoDocsWeb.ErrorHTML, json: OhMyJidoDocsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OhMyJidoDocs.PubSub,
  live_view: [signing_salt: "TT11eNQv"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  oh_my_jido_docs: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  oh_my_jido_docs: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Native Mix asset tasks load compile config unless --runtime-config is explicit.
if path = System.get_env("ESBUILD_PATH"), do: config(:esbuild, path: path)
if path = System.get_env("TAILWIND_PATH"), do: config(:tailwind, path: path)

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "preview_token"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
