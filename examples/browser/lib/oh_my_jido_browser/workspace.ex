defmodule OhMyJidoBrowser.Workspace do
  @moduledoc """
  The agent's workspace: an in-memory directory inside the browser VM.

  It starts as a copy of `priv/workspace`. The agent reads and writes these
  files with its ordinary tools; they are lost when the page reloads.
  """

  @root "/home/web_user/workspace"

  @doc "Absolute workspace root."
  @spec root() :: String.t()
  def root, do: @root

  @doc "Copies the packaged files into a fresh workspace."
  @spec prepare!() :: :ok
  def prepare! do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    {:ok, _files} = File.cp_r(Application.app_dir(:oh_my_jido_browser, "priv/workspace"), @root)
    :ok
  end
end
