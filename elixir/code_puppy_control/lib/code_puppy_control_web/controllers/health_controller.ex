defmodule CodePuppyControlWeb.HealthController do
  @moduledoc """
  Health check controller for load balancers and monitoring.
  """

  use CodePuppyControlWeb, :controller

  alias CodePuppyControl.Run.Supervisor, as: RunSupervisor

  @doc """
  GET /health

  Returns health status of the control plane.
  """
  def index(conn, _params) do
    # Collect basic stats
    stats = %{
      "status" => "healthy",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "version" => Application.spec(:code_puppy_control, :vsn) |> to_string(),
      "elixir_version" => System.version(),
      "uptime_seconds" => :erlang.statistics(:wall_clock) |> elem(0) |> div(1000),
      "workers" => %{
        "active_runs" => RunSupervisor.run_count()
      }
    }

    conn
    |> put_resp_header("cache-control", "no-cache")
    |> json(stats)
  end

  @doc """
  GET /health/runtime

  Returns a live snapshot of BEAM runtime state.
  """
  def runtime(conn, _params) do
    json(conn, CodePuppyControl.Runtime.Snapshot.snapshot())
  end
end
