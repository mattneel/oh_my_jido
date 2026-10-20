import Config

preview? = System.get_env("DOCS_PREVIEW") == "1"

editor? =
  not preview? and
    System.get_env("DOCS_EDITOR_ENABLED", if(config_env() == :prod, do: "0", else: "1")) == "1"

app_root = Path.expand("..", __DIR__)
data = Path.expand(System.get_env("DOCS_DATA_DIR", Path.join(app_root, "var")))
source = Path.expand(System.get_env("DOCS_SOURCE_ROOT", Path.expand("../..", app_root)))

config :oh_my_jido_docs,
  editor_enabled: editor?,
  preview: preview?,
  data_dir: data,
  source_root: source,
  published_root:
    Path.expand(System.get_env("DOCS_PUBLISHED_ROOT", Path.join(data, "published"))),
  static_docs_root: System.get_env("DOCS_STATIC_ROOT"),
  allow_test_scripts: false,
  model: if(editor?, do: System.get_env("DOCS_MODEL")),
  model_account: "docs-site",
  model_api_key: if(editor?, do: System.get_env("DOCS_MODEL_API_KEY")),
  operator_username: if(editor?, do: System.get_env("DOCS_OPERATOR_USERNAME", "editor")),
  operator_password_hash: if(editor?, do: System.get_env("DOCS_OPERATOR_PASSWORD_HASH")),
  flyctl: if(editor?, do: System.get_env("DOCS_FLYCTL")),
  fly_app: if(editor?, do: System.get_env("DOCS_FLY_APP")),
  fly_token: if(editor?, do: System.get_env("DOCS_FLY_TOKEN")),
  candidate_python_executable:
    if(editor?, do: System.get_env("DOCS_CANDIDATE_PYTHON", "python3")),
  candidate_release_name: "oh_my_jido_docs",
  candidate_toolchain_env:
    Map.reject(%{"MIX_REBAR3" => System.get_env("DOCS_MIX_REBAR3")}, fn {_key, value} ->
      is_nil(value)
    end),
  fly_dockerfile: "examples/docs_site/Dockerfile",
  fly_config: "examples/docs_site/fly.toml",
  candidate_native_caches:
    if(editor?,
      do: [
        rustler:
          System.get_env("DOCS_RUSTLER_CACHE") ||
            :filename.basedir(:user_cache, "rustler_precompiled/precompiled_nifs"),
        elixir_make:
          System.get_env("DOCS_ELIXIR_MAKE_CACHE") ||
            :filename.basedir(:user_cache, "elixir_make")
      ],
      else: []
    ),
  candidate_asset_tools: [
    esbuild: System.get_env("ESBUILD_PATH"),
    tailwind: System.get_env("TAILWIND_PATH")
  ]

if editor? do
  config :oh_my_jido_docs, OhMyJidoDocs.Repo,
    database: System.get_env("DATABASE_PATH", Path.join(data, "studio.db")),
    pool_size: 1,
    journal_mode: :wal,
    busy_timeout: 5_000,
    show_sensitive_data_on_connection_error: false
end

if path = System.get_env("ESBUILD_PATH"), do: config(:esbuild, path: path)
if path = System.get_env("TAILWIND_PATH"), do: config(:tailwind, path: path)

if System.get_env("PHX_SERVER") in ["true", "1"] do
  config :oh_my_jido_docs, OhMyJidoDocsWeb.Endpoint, server: true
end

config :oh_my_jido_docs, OhMyJidoDocsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  secret = System.fetch_env!("SECRET_KEY_BASE")
  if byte_size(secret) < 64, do: raise("SECRET_KEY_BASE must contain at least 64 bytes")
  host = System.get_env("PHX_HOST", "localhost")
  address = if preview?, do: {127, 0, 0, 1}, else: {0, 0, 0, 0, 0, 0, 0, 0}

  if editor? do
    hash = System.fetch_env!("DOCS_OPERATOR_PASSWORD_HASH")

    unless String.starts_with?(hash, "$pbkdf2-"),
      do: raise("Trusted editor requires a PBKDF2 password hash")

    for key <- ["DOCS_SOURCE_ROOT", "DOCS_DATA_DIR"] do
      unless Path.type(System.fetch_env!(key)) == :absolute, do: raise("#{key} must be absolute")
    end
  end

  config :oh_my_jido_docs, OhMyJidoDocsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: address],
    secret_key_base: secret
end

if config_env() == :test do
  config :oh_my_jido_docs,
    data_dir: Path.expand("../tmp/studio-test", __DIR__),
    published_root: Path.expand("../tmp/studio-test/published", __DIR__)

  config :oh_my_jido_docs, OhMyJidoDocs.Repo,
    database: Path.expand("../oh_my_jido_docs_test.db", __DIR__),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 1
end
