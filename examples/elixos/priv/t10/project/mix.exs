defmodule OhMyJidoGuest.Workload.MixProject do
  use Mix.Project

  def project, do: [app: :oh_my_jido_guest_workload, version: "0.1.0", elixir: "~> 1.20", deps: []]
  def application, do: [extra_applications: [:logger]]
end
