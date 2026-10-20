defmodule OhMyJidoDocsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Database access and real private worker ownership are delegated to DataCase.
  Synchronous cases keep those workers inside the shared sandbox lifetime;
  asynchronous cases cannot use the singleton editor/candidate owners.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint OhMyJidoDocsWeb.Endpoint

      use OhMyJidoDocsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import OhMyJidoDocsWeb.ConnCase
    end
  end

  setup tags do
    OhMyJidoDocs.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
