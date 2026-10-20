defmodule OhMyJidoDocs.Repo do
  use Ecto.Repo,
    otp_app: :oh_my_jido_docs,
    adapter: Ecto.Adapters.SQLite3
end
