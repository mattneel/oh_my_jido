defmodule Mix.Tasks.OhMyJidoBrowser.Serve do
  @shortdoc "Serves the cooked browser app on 127.0.0.1"
  @moduledoc """
  Serves a cooked build on the loopback interface only.

      MIX_ENV=prod mix popcorn.cook
      mix oh_my_jido_browser.serve --port 4010

  Options: `--port` (default `4010`) and `--dir` (default `public`).
  The server sends static files only; the agent runs in the browser.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [port: :integer, dir: :string])
    port = Keyword.get(opts, :port, 4010)
    dir = Keyword.get(opts, :dir, "public")

    {:ok, _apps} = Application.ensure_all_started(:bandit)

    {:ok, _server} =
      Bandit.start_link(
        plug: {OhMyJidoBrowser.StaticSite, dir: dir},
        ip: {127, 0, 0, 1},
        port: port,
        startup_log: false
      )

    Mix.shell().info("Serving #{dir} at http://127.0.0.1:#{port}/")
    Process.sleep(:infinity)
  end
end
