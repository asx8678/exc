defmodule CodePuppyControl.MCP.Supervisor do
  @moduledoc """
  DynamicSupervisor for MCP server processes.

  Each MCP server gets its own supervised process via `start_server/1`.
  Workers are started with `:transient` restart strategy so they restart
  on abnormal exit but not on normal shutdown.

  ## Usage

      {:ok, pid} = MCP.Supervisor.start_server(
        server_id: "files-abc123",
        name: "filesystem",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

  ## Monitoring

  Subscribe to PubSub topic `"mcp:*"` to receive notifications:
  - `{:mcp_notification, server_id, params}` - MCP server notifications
  - `{:mcp_quarantined, server_id, until}` - Server quarantine events
  """

  use DynamicSupervisor

  require Logger

  alias CodePuppyControl.MCP.Server

  @doc """
  Starts the MCP DynamicSupervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts an MCP server under supervision.

  ## Options

    * `:server_id` - Required. Unique identifier.
    * `:name` - Required. Human-readable name.
    * `:command` - Required. MCP server command.
    * `:args` - Optional. Command arguments.
    * `:env` - Optional. Environment variables.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_server(keyword()) :: DynamicSupervisor.on_start_child()
  def start_server(opts) do
    server_id = Keyword.fetch!(opts, :server_id)

    child_spec = %{
      id: {Server, server_id},
      start: {Server, :start_link, [opts]},
      restart: :transient,
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started MCP server #{server_id} (pid: #{inspect(pid)})")
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("MCP server #{server_id} already running (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, :max_children} ->
        limit = CodePuppyControl.Runtime.Limits.max_mcp_servers()

        Logger.warning(
          "MCP server supervisor at capacity (limit: #{limit}). " <>
            "Refusing to start server #{server_id}."
        )

        :telemetry.execute(
          [:code_puppy, :supervisor, :full],
          %{count: 1},
          %{supervisor: :mcp_server, server_id: server_id}
        )

        {:error, :max_children}

      {:error, reason} = error ->
        Logger.error("Failed to start MCP server #{server_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops an MCP server by server_id.

  Returns `:ok` on success or `{:error, :not_found}` if server doesn't exist.

  The stop proceeds in two stages:
  1. `Server.stop/1` — graceful GenServer shutdown (triggers `terminate/2`
     which closes the Port and emits telemetry).
  2. `DynamicSupervisor.terminate_child/2` — belt-and-suspenders cleanup.

  Because the child uses `:transient` restart, a normal exit from step 1
  causes the DynamicSupervisor to automatically remove the child.  So
  `terminate_child` may return `{:error, :not_found}` — that is expected
  and NOT propagated as an error, since the server was already stopped.
  """
  @spec stop_server(String.t()) :: :ok | {:error, :not_found}
  def stop_server(server_id) do
    case Registry.lookup(CodePuppyControl.MCP.Registry, server_id) do
      [] ->
        {:error, :not_found}

      [{pid, _value} | _] ->
        # Gracefully stop the GenServer.  May raise if the process exited
        # between the Registry lookup and this call (race), so catch that.
        try do
          Server.stop(server_id)
        catch
          :exit, _ -> :ok
        end

        # After Server.stop the child exits normally.  With :transient restart
        # the DynamicSupervisor removes it automatically, so terminate_child
        # may return {:error, :not_found} — that's expected, not an error.
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end
    end
  end

  @doc """
  Restarts an MCP server by server_id using explicit config.

  Stops the existing server if running, then starts a new one with
  the provided configuration.  This is the preferred restart path —
  the old `restart_server/1` variant (reading from Application env) is
  deprecated because Application env is not a reliable config source.

  ## Parameters

    * `server_id` - The current server identifier.
    * `config` - Keyword list with `:name`, `:command`, `:args`, `:env`.
      `:server_id` is optional; defaults to the existing `server_id`.

  ## Returns

    * `{:ok, pid}` on success.
    * `{:error, :not_found}` when `server_id` is not running.
    * `{:error, reason}` on start failure.
  """
  @spec restart_server_with_config(String.t(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def restart_server_with_config(server_id, config) do
    case Server.get_status(server_id) do
      status when is_map(status) ->
        stop_server(server_id)
        Process.sleep(100)

        new_config =
          Keyword.put_new(config, :server_id, server_id)

        start_server(new_config)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Restarts an MCP server by server_id.

  Stops the existing server if running, then starts a new one with
  the same configuration read from Application env.

  > **Deprecated:** Use `restart_server_with_config/2` instead, which
  > reads configuration from `mcp_servers.json` rather than the fragile
  > Application env store.
  """
  @spec restart_server(String.t()) :: DynamicSupervisor.on_start_child() | {:error, :not_found}
  def restart_server(server_id) do
    case Server.get_status(server_id) do
      status when is_map(status) ->
        stop_server(server_id)
        Process.sleep(100)

        start_server(
          server_id: status.server_id,
          name: status.name,
          command:
            Application.get_env(:code_puppy_control, :mcp_servers, %{})[status.name]["command"],
          args: Application.get_env(:code_puppy_control, :mcp_servers, %{})[status.name]["args"],
          env: Application.get_env(:code_puppy_control, :mcp_servers, %{})[status.name]["env"]
        )

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running MCP server IDs.
  """
  @spec list_servers() :: list(String.t())
  def list_servers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, [Server]} when is_pid(pid) ->
        case Server.pid_to_server_id(pid) do
          {:ok, server_id} -> [server_id]
          :error -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns the number of active MCP servers.
  """
  @spec server_count() :: non_neg_integer()
  def server_count do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(__MODULE__).workers
    end
  end

  @doc """
  Returns detailed information about all MCP servers.
  """
  @spec server_details() :: list(map())
  def server_details do
    list_servers()
    |> Enum.map(&Server.get_status/1)
    |> Enum.reject(&match?({:error, _}, &1))
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60,
      max_children: CodePuppyControl.Runtime.Limits.max_mcp_servers()
    )
  end
end
