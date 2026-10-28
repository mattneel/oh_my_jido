defmodule OhMyJidoBrowser.BrowserTest do
  @moduledoc """
  Builds the end-to-end bundle (`MIX_ENV=e2e`), serves it on the loopback
  interface and runs the Chromium suite in `e2e/` against it with Playwright.

  Needs `npm ci` and the Playwright Chromium headless shell
  (`npx playwright install chromium-headless-shell`).
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 900_000

  @static ~w(index.html app.js app.css secrets.js eval.js python-kernel.js)
  @runtimes ~w(pyodide vendor/web-llm vendor/web_llm)

  setup_all do
    root = File.cwd!()
    site = Path.join(root, "tmp/e2e")
    Mix.Task.run("oh_my_jido_browser.assets")
    File.rm_rf!(site)
    File.mkdir_p!(site)

    for file <- @static, do: File.cp!(Path.join([root, "public", file]), Path.join(site, file))

    for dir <- @runtimes do
      target = Path.join(site, dir)
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(Path.join([root, "public", dir]), target)
    end

    {output, status} =
      System.cmd("mix", ["popcorn.cook", "--out-dir", Path.join(site, "out")],
        env: [{"MIX_ENV", "e2e"}],
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("cooking the end-to-end build failed:\n" <> output)

    server =
      start_supervised!(
        {Bandit,
         plug: {OhMyJidoBrowser.StaticSite, dir: site},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{root: root, url: "http://127.0.0.1:#{port}"}
  end

  test "the agent runs and changes its own page in Chromium", %{root: root, url: url} do
    {output, status} =
      System.cmd("npx", ["playwright", "test", "--config", "e2e/playwright.config.js"],
        cd: root,
        env: [{"OMJ_BASE_URL", url}],
        stderr_to_stdout: true
      )

    IO.puts(output)
    assert status == 0, "the Chromium end-to-end suite failed"
  end
end
