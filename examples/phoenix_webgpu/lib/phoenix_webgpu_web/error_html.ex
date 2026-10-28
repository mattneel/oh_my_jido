defmodule PhoenixWebGPUWeb.ErrorHTML do
  @moduledoc "Plain-text HTTP error responses."

  @doc "Renders the status message without exposing server details."
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
