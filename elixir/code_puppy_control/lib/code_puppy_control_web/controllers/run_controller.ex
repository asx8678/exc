defmodule CodePuppyControlWeb.RunController do
  @moduledoc """
  Controller for run management API endpoints.

  Uses Run.Manager for high-level run coordination.
  """

  use CodePuppyControlWeb, :controller

  require Logger

  alias CodePuppyControl.Run.Manager

  @doc """
  POST /api/runs

  Creates a new run with an associated Python worker.
  """
  def create(conn, %{"session_id" => session_id, "agent_name" => agent_name} = params) do
    config = Map.get(params, "config", %{})
    metadata = Map.get(params, "metadata", %{})

    case Manager.start_run(session_id, agent_name,
           config: config,
           metadata: metadata
         ) do
      {:ok, run_id} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: run_id,
          session_id: session_id,
          agent_name: agent_name,
          status: "starting",
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, reason} ->
        Logger.error("Failed to create run: #{inspect(reason)}")

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create run", details: inspect(reason)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required fields: session_id and agent_name"})
  end

  @doc """
  GET /api/runs/:id

  Gets the current status of a run.
  """
  def show(conn, %{"id" => run_id}) do
    case Manager.get_run(run_id) do
      {:ok, state} ->
        json(conn, %{
          id: run_id,
          session_id: state.session_id,
          agent_name: state.agent_name,
          status: state.status,
          started_at: format_datetime(state.started_at),
          completed_at: format_datetime(state.completed_at),
          error: state.error,
          metadata: state.metadata,
          event_count: length(state.events)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Run not found"})
    end
  end

  @doc """
  GET /api/runs

  Lists runs, optionally filtered by session_id.
  """
  def index(conn, params) do
    session_id = Map.get(params, "session_id")
    runs = Manager.list_runs_with_details(session_id)

    json(conn, %{
      runs: runs,
      count: length(runs)
    })
  end

  @doc """
  DELETE /api/runs/:id

  Stops and cleans up a run.
  """
  def delete(conn, %{"id" => run_id}) do
    Logger.info("Deleting run #{run_id}")

    case Manager.delete_run(run_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Run not found"})
    end
  end

  @doc """
  POST /api/runs/:id/cancel

  Cancels a running run.
  """
  def cancel(conn, %{"id" => run_id} = params) do
    reason = Map.get(params, "reason", "user_cancelled")

    case Manager.cancel_run(run_id, reason) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{
          id: run_id,
          status: "cancelled",
          cancelled_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Run not found"})
    end
  end

  @doc """
  POST /api/runs/:id/execute

  Executes a tool via the runtime-selected executor.

  Routes through `Run.Manager.execute_tool/4`, which dispatches
  to the executor backend stored in the run's metadata at start
  time (Elixir-native `Tool.Runner` or Python bridge `Port.call/4`).

  Refs: code-puppy-zyh
  """
  def execute(conn, %{"id" => run_id} = params) do
    tool_name = Map.get(params, "tool_name") || Map.get(params, "tool")
    arguments = Map.get(params, "arguments") || Map.get(params, "args", %{})

    if is_nil(tool_name) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required field: tool_name"})
    else
      case Manager.execute_tool(run_id, tool_name, arguments) do
        {:ok, result} ->
          conn
          |> put_status(:ok)
          |> json(%{
            run_id: run_id,
            tool_name: tool_name,
            result: result,
            executed_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Run not found"})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            run_id: run_id,
            tool_name: tool_name,
            error: inspect(reason)
          })
      end
    end
  end

  @doc """
  GET /api/runs/:id/history

  Gets the request/response history for a run.
  """
  def history(conn, %{"id" => run_id}) do
    case CodePuppyControl.Run.State.get_history(run_id) do
      [] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Run not found or no history"})

      history ->
        json(conn, %{
          run_id: run_id,
          history: Enum.reverse(history)
        })
    end
  end

  # Private functions

  defp format_datetime(nil), do: nil

  defp format_datetime(dt) do
    DateTime.to_iso8601(dt)
  end
end
