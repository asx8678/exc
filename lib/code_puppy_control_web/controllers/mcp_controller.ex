defmodule CodePuppyControlWeb.MCPController do
  @moduledoc """
  REST API controller for MCP server management.

  ## Endpoints

  ### Server Management
  - `GET /api/mcp` - List all MCP servers
  - `POST /api/mcp` - Register a new MCP server
  - `GET /api/mcp/:id` - Get server status
  - `DELETE /api/mcp/:id` - Unregister a server

  ### Tool Execution
  - `POST /api/mcp/:id/call` - Call a tool on an MCP server

  ### Health & Monitoring
  - `GET /api/mcp/health` - Get health status of all servers
  """

  use CodePuppyControlWeb, :controller

  require Logger

  alias CodePuppyControl.MCP.Manager

  @doc """
  GET /api/mcp

  Lists all MCP servers with their current status.
  """
  def index(conn, _params) do
    servers = Manager.list_servers()

    json(conn, %{
      servers: servers,
      count: length(servers),
      stats: Manager.stats()
    })
  end

  @doc """
  POST /api/mcp

  Registers a new MCP server.

  ## Request Body

      {
        "name": "filesystem",
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        "env": {"HOME": "/home/user"}
      }

  ## Response

      {
        "server_id": "filesystem-abc123",
        "name": "filesystem",
        "status": "starting"
      }
  """
  def create(conn, %{"name" => name, "command" => command} = params) do
    opts = [
      args: params["args"] || [],
      env: params["env"] || %{}
    ]

    case Manager.register_server(name, command, opts) do
      {:ok, server_id} ->
        conn
        |> put_status(:created)
        |> json(%{
          server_id: server_id,
          name: name,
          status: "starting"
        })

      {:error, reason} ->
        Logger.error("Failed to register MCP server #{name}: #{inspect(reason)}")

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to register server", details: inspect(reason)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required fields: name and command"})
  end

  @doc """
  GET /api/mcp/:id

  Gets the current status of an MCP server.
  """
  def show(conn, %{"id" => server_id}) do
    case Manager.get_server_status(server_id) do
      status when is_map(status) ->
        json(conn, status)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Server not found"})
    end
  end

  @doc """
  DELETE /api/mcp/:id

  Unregisters and stops an MCP server.
  """
  def delete(conn, %{"id" => server_id}) do
    case Manager.unregister_server(server_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Server not found"})
    end
  end

  @doc """
  POST /api/mcp/:id/call

  Calls a tool on an MCP server.

  ## Request Body

      {
        "method": "read_file",
        "params": {"path": "/tmp/test.txt"}
      }

  ## Response (Success)

      {
        "result": {"content": "..."}
      }

  ## Response (Quarantined)

      {
        "error": "Server is quarantined due to repeated failures"
      }
  """
  def call_tool(conn, %{"id" => server_id} = params) do
    method = Map.get(params, "method") || Map.get(params, "tool")
    params = Map.get(params, "params") || Map.get(params, "arguments", %{})
    timeout = Map.get(params, "timeout", 30_000)

    if is_nil(method) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required field: method"})
    else
      case Manager.call_tool(server_id, method, params, timeout: timeout) do
        {:ok, result} ->
          json(conn, %{result: result})

        {:error, :quarantined} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{
            error: "Server is quarantined due to repeated failures",
            retry_after: estimate_retry_after(server_id)
          })

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "Tool execution failed", details: inspect(reason)})
      end
    end
  end

  @doc """
  GET /api/mcp/health

  Returns health status of all MCP servers.
  """
  def health(conn, _params) do
    results = Manager.health_check_all()

    healthy_count = Enum.count(results, fn {_, health} -> health == :healthy end)
    unhealthy = Enum.filter(results, fn {_, health} -> match?({:unhealthy, _}, health) end)

    status =
      if healthy_count == length(results) do
        :healthy
      else
        :degraded
      end

    conn
    |> put_status(if(status == :healthy, do: :ok, else: :service_unavailable))
    |> json(%{
      status: status,
      total: length(results),
      healthy: healthy_count,
      unhealthy: length(unhealthy),
      details: Enum.into(unhealthy, %{})
    })
  end

  @doc """
  POST /api/mcp/:id/restart

  Restarts an MCP server.
  """
  def restart(conn, %{"id" => server_id}) do
    case Manager.restart_server(server_id) do
      {:ok, _pid} ->
        json(conn, %{
          server_id: server_id,
          status: "restarting"
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Server not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to restart server", details: inspect(reason)})
    end
  end

  # Private functions

  defp estimate_retry_after(server_id) do
    case Manager.get_server_status(server_id) do
      %{quarantine_until: until} when not is_nil(until) ->
        now = DateTime.utc_now()

        case DateTime.compare(until, now) do
          :gt -> DateTime.diff(until, now, :second)
          _ -> 30
        end

      _ ->
        30
    end
  end
end
