defmodule PhoenixWebGPU.BrowserTest do
  @moduledoc "Runs deterministic Chromium scenarios against the real endpoint and LiveView socket."
  use ExUnit.Case, async: false

  @moduletag timeout: 900_000

  setup_all do
    server =
      start_supervised!(
        {Bandit, plug: PhoenixWebGPUWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "a server parent delegates to the GPU in the correct tab", %{url: url} do
    {output, status} =
      System.cmd(
        "npx",
        ["--no-install", "playwright", "test", "--config", "e2e/playwright.config.js"],
        cd: Path.expand("..", __DIR__),
        env: [{"OMJ_BASE_URL", url}],
        stderr_to_stdout: true
      )

    assert status == 0, "Chromium end-to-end suite failed:\n" <> output
  end
end
