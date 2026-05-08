defmodule CodePuppyControl.MCP.Manager do
  @moduledoc """
  High-level API for managing MCP servers.

  This module provides a simple interface for:
  - Registering/unregistering MCP servers
  - Calling tools on MCP servers
  - Querying server status and health
  - Bulk health check operations

  ## Usage

      # Register a new MCP server
      {:ok, server_id} = MCP.Manager.register_server(
        "filesystem",
        "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      # Call a tool
      {:ok, result} = MCP.Manager.call_tool(server_id, "read_file", %{"path" => "/tmp/test.txt"})

      # Check status
      status = MCP.Manager.get_server_status(server_id)

      # Cleanup
      :ok = MCP.Manager.unregister_server(server_id)

  ## PubSub Events

  Subscribe to `CodePuppyControl.PubSub` with topic `"mcp:<server_id>"` to receive:
  - `{:mcp_notification, server_id, params}` - Server notifications
  - `{:mcp_quarantined, server_id, until}` - Quarantine events
  """

  require Logger

  alias CodePuppyControl.MCP.{Server, Supervisor}

  @doc """
  Registers a new MCP server with the system.

  Generates a unique server_id and starts the server under supervision.

  ## Parameters

    * `name` - Human-readable name for the server.
    * `command` - The MCP server executable command.
    * `opts` - Optional keyword list:
      * `:server_id` - Override auto-generated ID.
      * `:args` - Command line arguments.
      * `:env` - Environment variables.

  ## Returns

    * `{:ok, server_id}` - Server started successfully.
    * `{:error, reason}` - Failed to start server.

  ## Examples

      {:ok, server_id} = MCP.Manager.register_server(
        "filesystem",
        "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        env: %{"HOME" => "/home/user"}
      )
  """
  @spec register_server(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_server(name, command, opts \\ []) do
    server_id = opts[:server_id] || generate_server_id(name)

    Logger.info("Registering MCP server #{name} as #{server_id}")

    server_opts = [
      server_id: server_id,
      name: name,
      command: command,
      args: opts[:args] || [],
      env: opts[:env] || %{}
    ]

    case Supervisor.start_server(server_opts) do
      {:ok, _pid} -> {:ok, server_id}
      {:error, _} = error -> error
    end
  end

  @doc """
  Unregisters an MCP server and stops it.

  ## Returns

    * `:ok` - Server stopped successfully.
    * `{:error, :not_found}` - Server not found.
  """
  @spec unregister_server(String.t()) :: :ok | {:error, :not_found}
  def unregister_server(server_id) do
    Logger.info("Unregistering MCP server #{server_id}")
    Supervisor.stop_server(server_id)
  end

  @doc """
  Calls a tool on an MCP server.

  ## Parameters

    * `server_id` - The server identifier.
    * `method` - Tool method name.
    * `params` - Tool parameters.
    * `opts` - Optional:
      * `:timeout` - Request timeout in milliseconds (default 30_000).

  ## Returns

    * `{:ok, result}` - Tool executed successfully.
    * `{:error, :quarantined}` - Server is quarantined.
    * `{:error, reason}` - Tool execution failed.

  ## Examples

      {:ok, %{"content" => content}} = MCP.Manager.call_tool(
        server_id,
        "read_file",
        %{"path" => "/tmp/test.txt"}
      )
  """
  @spec call_tool(String.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call_tool(server_id, method, params, opts \\ []) do
    timeout = opts[:timeout] || 30_000
    Server.call_tool(server_id, method, params, timeout)
  end

  @doc """
  Gets the status of an MCP server.

  Returns a map with server details or `{:error, :not_found}`.
  """
  @spec get_server_status(String.t()) :: map() | {:error, :not_found}
  def get_server_status(server_id) do
    Server.get_status(server_id)
  end

  @doc """
  Lists all registered MCP servers with their status.

  Returns a list of status maps, one for each server.
  """
  @spec list_servers() :: list(map())
  def list_servers do
    Supervisor.list_servers()
    |> Enum.map(&Server.get_status/1)
    |> Enum.reject(&match?({:error, _}, &1))
  end

  @doc """
  Performs health checks on all MCP servers.

  Returns a list of `{server_id, health}` tuples where health is:
  - `:healthy` - Server is healthy
  - `{:unhealthy, reason}` - Server is unhealthy

  ## Examples

      results = MCP.Manager.health_check_all()
      # [{"files-abc123", :healthy}, {"git-xyz789", {:unhealthy, :timeout}}]
  """
  @spec health_check_all() :: list({String.t(), :healthy | {:unhealthy, term()}})
  def health_check_all do
    Supervisor.list_servers()
    |> Enum.map(fn server_id ->
      {server_id, Server.health_check(server_id)}
    end)
  end

  @doc """
  Gets summary statistics for all MCP servers.

  Returns a map with counts by health status.
  """
  @spec stats() :: map()
  def stats do
    servers = list_servers()

    total = length(servers)
    healthy = Enum.count(servers, &(&1.health == :healthy))
    degraded = Enum.count(servers, &(&1.health == :degraded))
    unhealthy = Enum.count(servers, &(&1.health == :unhealthy))
    quarantined = Enum.count(servers, & &1.quarantined)

    %{
      total: total,
      healthy: healthy,
      degraded: degraded,
      unhealthy: unhealthy,
      quarantined: quarantined
    }
  end

  @doc """
  Restarts an MCP server.

  Useful for recovering from quarantine or other error states.
  """
  @spec restart_server(String.t()) :: {:ok, pid()} | {:error, term()}
  def restart_server(server_id) do
    Supervisor.restart_server(server_id)
  end

  # ── Config-driven lifecycle helpers ───────────────────────────────────

  alias CodePuppyControl.Config.Paths

  @doc """
  Reads configured MCP servers from `mcp_servers.json`.

  Returns a list of maps, each with a `"name"` key injected from the
  top-level key.  Skips entries whose value is not a map.
  """
  @spec read_configured_servers() :: [map()]
  def read_configured_servers do
    path = Paths.mcp_servers_file()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"mcp_servers" => servers}} when is_map(servers) ->
            servers_to_list(servers)

          {:ok, flat} when is_map(flat) ->
            if Enum.any?(flat, fn {_k, v} -> is_map(v) end) do
              servers_to_list(flat)
            else
              []
            end

          {:ok, _other} ->
            []

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Finds a server config map by name from `mcp_servers.json`.

  Returns the config map (with `"name"` key) or `nil`.
  """
  @spec find_server_config_by_name(String.t()) :: map() | nil
  def find_server_config_by_name(name) do
    read_configured_servers()
    |> Enum.find(fn cfg -> String.downcase(cfg["name"] || "") == String.downcase(name) end)
  end

  @doc """
  Finds the `server_id` of a currently running server by its
  configured name (case-insensitive).

  Returns `{:ok, server_id}` or `{:error, :not_found}`.
  """
  @spec find_server_id_by_name(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def find_server_id_by_name(name) do
    list_servers()
    |> Enum.find(fn status ->
      String.downcase(to_string(status.name)) == String.downcase(name)
    end)
    |> case do
      nil -> {:error, :not_found}
      status -> {:ok, status.server_id}
    end
  end

  @doc """
  Starts a configured MCP server by name.

  Reads the server definition from `mcp_servers.json`, checks whether
  the server is already running, and starts it if not.

  ## Returns

    * `{:ok, server_id}` — server started successfully.
    * `{:ok, :already_running}` — server is already running.
    * `{:error, :not_configured}` — no such server in config.
    * `{:error, reason}` — start failed.
  """
  @spec start_server_by_name(String.t()) ::
          {:ok, String.t()} | {:ok, :already_running} | {:error, term()}
  def start_server_by_name(name) do
    case find_server_config_by_name(name) do
      nil ->
        {:error, :not_configured}

      cfg ->
        # Use the canonical configured name (preserves original casing)
        # so that /mcp list and /mcp status join correctly even when the
        # user types a different casing (e.g. /mcp start myserver → "MyServer").
        canonical_name = cfg["name"]

        # Check if already running
        case find_server_id_by_name(canonical_name) do
          {:ok, _server_id} ->
            {:ok, :already_running}

          {:error, :not_found} ->
            register_server(
              canonical_name,
              cfg["command"] || "",
              args: cfg["args"] || [],
              env: cfg["env"] || %{}
            )
        end
    end
  end

  @doc """
  Stops a running MCP server by its configured name.

  ## Returns

    * `:ok` — server stopped.
    * `{:error, :not_running}` — no running server with that name.
  """
  @spec stop_server_by_name(String.t()) :: :ok | {:error, :not_running}
  def stop_server_by_name(name) do
    case find_server_id_by_name(name) do
      {:ok, server_id} ->
        unregister_server(server_id)

      {:error, :not_found} ->
        {:error, :not_running}
    end
  end

  @doc """
  Restarts an MCP server by name, reading fresh config from disk.

  If the server is running, stops it first.  Then starts a new instance
  using the latest config from `mcp_servers.json`.

  ## Returns

    * `{:ok, server_id}` — restarted successfully.
    * `{:error, :not_configured}` — server not in config file.
    * `{:error, reason}` — start failed.
  """
  @spec restart_server_by_name(String.t()) :: {:ok, String.t()} | {:error, term()}
  def restart_server_by_name(name) do
    case find_server_config_by_name(name) do
      nil ->
        {:error, :not_configured}

      cfg ->
        # Use the canonical configured name (preserves original casing)
        canonical_name = cfg["name"]

        # Stop if running
        case find_server_id_by_name(canonical_name) do
          {:ok, server_id} ->
            unregister_server(server_id)
            Process.sleep(100)

          {:error, :not_found} ->
            :ok
        end

        register_server(
          canonical_name,
          cfg["command"] || "",
          args: cfg["args"] || [],
          env: cfg["env"] || %{}
        )
    end
  end

  @doc """
  Starts all configured MCP servers that are not already running.

  Returns a list of `{name, result}` tuples.
  """
  @spec start_all_configured() :: [{String.t(), atom() | tuple()}]
  def start_all_configured do
    read_configured_servers()
    |> Enum.map(fn cfg ->
      name = cfg["name"] || "unknown"
      result = start_server_by_name(name)
      {name, result}
    end)
  end

  @doc """
  Stops all running MCP servers.

  Returns a list of `{name, result}` tuples.
  """
  @spec stop_all_running() :: [{String.t(), :ok | {:error, term()}}]
  def stop_all_running do
    list_servers()
    |> Enum.map(fn status ->
      name = to_string(status.name)
      result = unregister_server(status.server_id)
      {name, result}
    end)
  end

  @doc """
  Stops all MCP servers.

  This is useful for shutdown or cleanup operations.
  """
  @spec stop_all() :: :ok
  def stop_all do
    Supervisor.list_servers()
    |> Enum.each(&unregister_server/1)

    :ok
  end

  # Private functions

  defp generate_server_id(name) do
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{name}-#{random_suffix}"
  end

  defp servers_to_list(servers_map) do
    servers_map
    |> Enum.filter(fn {_name, cfg} -> is_map(cfg) end)
    |> Enum.map(fn {name, cfg} ->
      Map.put(cfg, "name", name)
    end)
  end
end
