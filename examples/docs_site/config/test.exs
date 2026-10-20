import Config

# Private reconcilers must share one test's sandbox and stop before its owner.
config :oh_my_jido_docs,
  secure_session_cookie: false,
  migrate_on_start: false,
  start_private_workers: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :oh_my_jido_docs, OhMyJidoDocs.Repo,
  database: Path.expand("../oh_my_jido_docs_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :oh_my_jido_docs, OhMyJidoDocsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wPEu8TeV8BwcIAHfdslKJeoZCZURj+seoXivBYJbQChEhvW05sq6NtM++tlnHiCJ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
