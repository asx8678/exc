defmodule CodePuppyControlWeb.ConnCase do
  @moduledoc """
  Conveniences for testing Phoenix controllers.

  Uses `Phoenix.ConnTest` with the CodePuppyControlWeb endpoint.
  Provides `build_conn/0` and helpers for JSON API testing.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Jason.Helpers
      import CodePuppyControlWeb.ConnCase.Helpers

      @endpoint CodePuppyControlWeb.Endpoint
    end
  end

  defmodule Helpers do
    @moduledoc """
    Helper functions for controller tests.
    """

    @endpoint CodePuppyControlWeb.Endpoint

    @doc """
    Sends a JSON POST request.
    """
    def post_json(conn, path, body) do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.dispatch(@endpoint, :post, path, Jason.encode!(body))
    end

    @doc """
    Sends a JSON PUT request.
    """
    def put_json(conn, path, body) do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Phoenix.ConnTest.dispatch(@endpoint, :put, path, Jason.encode!(body))
    end
  end
end
