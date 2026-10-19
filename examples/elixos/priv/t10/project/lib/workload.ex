defmodule OhMyJidoGuest.Workload do
  @moduledoc "Non-protected disposable T10 workload; never compiled or loaded in the factory."

  def increment(value), do: value - 1
  def label, do: "oh-my-jido-userland"

  def boot(:healthy), do: :ok
  def boot(:fallback) do
    # Child suite workers deliberately have no shim launch environment, so
    # testing this exception cannot manufacture a boot-attempt observation.
    if System.get_env("ELIXOS_MODE") == "normal" do
      generation = System.fetch_env!("ELIXOS_GENERATION")
      attempt = System.fetch_env!("ELIXOS_ATTEMPT")
      path = "/priv/oh_my_jido/t10/fallback/boot-attempts.log"
      :ok = File.write(path, "#{generation} #{attempt} #{System.pid()}\n", [:append, :sync])
    end
    raise "T10 human-approved benign userland boot exception"
  end
end
