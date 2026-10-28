defmodule OhMyJidoBrowser.StaticSite do
  @moduledoc """
  Serves a cooked browser build as static files with the headers Popcorn requires.

  Only files below the configured directory are served, and `/` returns
  `index.html`. The content security policy lets the page talk to itself,
  to OpenRouter, and to the Hugging Face and GitHub hosts WebLLM downloads
  model weights and libraries from.
  """

  @behaviour Plug

  import Plug.Conn

  @headers [
    {"cross-origin-opener-policy", "same-origin"},
    {"cross-origin-embedder-policy", "require-corp"},
    {"content-security-policy",
     "default-src 'self'; script-src 'self' 'unsafe-eval' 'wasm-unsafe-eval'; " <>
       "worker-src 'self'; connect-src 'self' https://openrouter.ai " <>
       "https://huggingface.co https://*.huggingface.co https://*.hf.co " <>
       "https://raw.githubusercontent.com; " <>
       "style-src 'self' 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; " <>
       "form-action 'none'; frame-ancestors 'none'"},
    {"cache-control", "no-cache"},
    {"referrer-policy", "no-referrer"},
    {"x-content-type-options", "nosniff"}
  ]

  @impl true
  def init(opts) do
    dir = opts |> Keyword.fetch!(:dir) |> Path.expand()
    %{dir: dir, static: Plug.Static.init(from: dir, at: "/", gzip: true, brotli: true)}
  end

  @impl true
  def call(conn, %{dir: dir, static: static}) do
    conn
    |> merge_resp_headers(@headers)
    |> Plug.Static.call(static)
    |> fallback(dir)
  end

  defp fallback(%Plug.Conn{halted: true} = conn, _dir), do: conn

  defp fallback(%Plug.Conn{request_path: "/"} = conn, dir) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Path.join(dir, "index.html"))
    |> halt()
  end

  defp fallback(conn, _dir), do: conn |> send_resp(404, "not found") |> halt()
end
