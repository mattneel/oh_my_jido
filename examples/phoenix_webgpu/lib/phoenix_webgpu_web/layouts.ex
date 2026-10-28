defmodule PhoenixWebGPUWeb.Layouts do
  @moduledoc "HTML shell with dependency import maps instead of an asset build."
  use Phoenix.Component

  @doc "Root document and native module configuration."
  attr :inner_content, :any, required: true

  def root(assigns) do
    assigns =
      assign(assigns,
        module_url: Application.fetch_env!(:phoenix_webgpu, :web_llm_module_url),
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <meta name="web-llm-module-url" content={@module_url} />
        <title>Server agent · Browser GPU</title>
        <link rel="stylesheet" href="/app.css" />
        <script type="importmap" phx-no-curly-interpolation>
          {"imports":{"phoenix":"/deps/phoenix/phoenix.mjs","phoenix_live_view":"/deps/phoenix_live_view/phoenix_live_view.esm.js","web_llm":"/deps/web_llm/web_llm.js"}}
        </script>
        <script type="module" src="/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
