defmodule OhMyJidoDocsWeb.Layouts do
  use OhMyJidoDocsWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :operator, :string, default: nil
  attr :studio, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="skip-link">Skip to content</a>
    <header class="site-header">
      <a href={~p"/"} class="site-brand" aria-label="OhMyJido documentation home"><span
        class="brand-mark"
        aria-hidden="true"
      >j.</span><span>OhMyJido <small>docs</small></span></a>
      <nav aria-label="Main navigation" class="header-nav">
        <a href={~p"/"} aria-current={!@studio && "page"}>Documentation</a>
        <a
          :if={OhMyJidoDocsWeb.OperatorAuth.editor_enabled?()}
          href={~p"/studio"}
          aria-current={@studio && "page"}
        >Studio <.icon name="hero-command-line" class="size-4" /></a>
      </nav>
      <div :if={OhMyJidoDocsWeb.OperatorAuth.editor_enabled?()} class="header-account">
        <span :if={@operator} class="operator-name"><span class="status-dot" />{@operator}</span>
        <.link
          :if={@operator}
          href={~p"/logout"}
          method="delete"
          class="btn btn-ghost btn-sm"
          id="sign-out"
        >Sign out</.link>
        <a :if={!@operator} href={~p"/login"} class="btn btn-sm btn-outline">Editor sign in</a>
      </div>
    </header>
    <main id="main-content">{render_slot(@inner_block)}</main>
    <footer class="site-footer">
      <a href={~p"/"}>OhMyJido</a><span>Native agent loop. Human-owned source.</span><span>Built with Jido + Phoenix</span>
    </footer>
    <.flash_group flash={@flash} />
    """
  end

  attr :pages, :list, required: true
  attr :current_slug, :string, default: nil

  def docs_nav(assigns) do
    ~H"""
    <aside class="docs-sidebar">
      <details open class="docs-navigation">
        <summary>Documentation <.icon name="hero-chevron-down" class="size-4" /></summary>
        <nav aria-label="Documentation pages">
          <a
            href={~p"/"}
            class={is_nil(@current_slug) && "active"}
            aria-current={is_nil(@current_slug) && "page"}
          ><.icon name="hero-squares-2x2" class="size-4" />Overview</a>
          <p class="nav-label">GUIDES & REFERENCE</p>
          <a
            :for={page <- @pages}
            href={~p"/docs/#{String.split(page.slug, "/")}"}
            class={@current_slug == page.slug && "active"}
            aria-current={@current_slug == page.slug && "page"}
          >{page.title}</a>
        </nav>
      </details>
      <div class="sidebar-note">
        <.icon name="hero-document-text" class="size-5" /><p>
          Reading the published source. Drafts stay in Studio.
        </p>
      </div>
    </aside>
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="Connection interrupted"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting. The host keeps running your work; this view reloads durable history on reconnect.
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title="Studio is reconnecting"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Host work is independent of this connection. Refresh if the connection does not recover.
      </.flash>
    </div>
    """
  end
end
