defmodule OhMyJidoDocsWeb.SessionHTML do
  use OhMyJidoDocsWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} operator={@operator}>
      <div class="login-shell">
        <section class="login-context">
          <p class="eyebrow">EDITORIAL STUDIO</p>
          <h1>Change the source.<br />Review the result.</h1>
          <p>
            One workspace for the real edit, check, preview, and publication loop. The public site stays on the last published snapshot.
          </p>
          <ol class="login-steps">
            <li><span>01</span> Ask for a source change</li><li>
              <span>02</span> Inspect tools, decisions, and diff
            </li><li><span>03</span> Check, preview, approve, publish</li>
          </ol>
        </section>
        <section class="panel login-panel" aria-labelledby="login-heading">
          <p class="eyebrow">AUTHORIZED OPERATOR ONLY</p>
          <h2 id="login-heading">Sign in to Studio</h2>
          <p class="muted">Use the operator credentials configured for this installation.</p>
          <p :if={@error} id="login-error" role="alert" class="inline-error">{@error}</p>
          <p :if={!@configured?} id="login-unavailable" role="alert" class="inline-error">
            Editorial login is not configured. Set an operator username and a PBKDF2 password hash on the host.
          </p>
          <.form for={@form} action={~p"/login"} id="login-form" class="form-stack">
            <.input
              field={@form[:username]}
              label="Username"
              autocomplete="username"
              required
              maxlength="200"
              disabled={!@configured?}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              required
              maxlength="1024"
              disabled={!@configured?}
            />
            <button class="btn btn-primary w-full" disabled={!@configured?}>Sign in
            <.icon name="hero-arrow-right" class="size-4" /></button>
          </.form>
          <p class="login-footnote">
            <.icon name="hero-lock-closed" class="size-4" />
            Signed, expiring session · No public registration
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
