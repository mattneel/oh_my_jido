import Config

config :logger, :default_formatter, metadata: [:session_id, :callback, :failure_kind]

config :jido_action, default_timeout: 30_000, default_max_retries: 0, default_backoff: 250

config :jido_ai,
  model_aliases: %{
    capable: "anthropic:claude-sonnet-4-6",
    fast: "anthropic:claude-haiku-4-5"
  }

config :oh_my_jido,
  default_role: :coding,
  model_roles: %{
    coding: :capable,
    planning: :capable,
    exploration: :fast,
    review: :capable,
    advisor: :capable,
    compaction: :fast
  }
