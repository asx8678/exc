defmodule CodePuppyControlWeb.InfoController do
  @moduledoc """
  Root info endpoint — replaces FastAPI GET / handler.

  Returns app identity and status for health-check probes and clients.
  Unlike the Python version (which returns an HTML landing page),
  this returns JSON — the Elixir server is API-only.
  """

  use CodePuppyControlWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{
      app: "code_puppy_control",
      version: Application.spec(:code_puppy_control, :vsn) |> to_string(),
      status: "ok",
      endpoints: %{
        health: "/health",
        api: "/api",
        websocket: "/socket"
      }
    })
  end
end
