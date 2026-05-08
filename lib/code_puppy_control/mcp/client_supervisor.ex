defmodule CodePuppyControl.MCP.ClientSupervisor do
  @moduledoc """
  DynamicSupervisor for MCP client processes.

  Each MCP server connection gets its own supervised `MCP.Client` process
  with `:transient` restart strategy (restarts on abnormal exit, not on
  normal shutdown).

  ## Usage

      {:ok, pid} = MCP.ClientSupervisor.start_client(
        id: "filesystem",
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

  ## Supervision

  This supervisor is started by the application supervision tree under
  `CodePuppyControl.Application`. If a client process crashes, it will be
  restarted by the DynamicSupervisor with backoff handled by the client itself.
  """

  use DynamicSupervisor

  require Logger

  alias CodePuppyControl.MCP.Client

  @doc "Starts the DynamicSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts an MCP client under supervision.

  See `CodePuppyControl.MCP.Client.start_link/1` for required options.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_client(keyword()) :: DynamicSupervisor.on_start_child()
  def start_client(opts) do
    id = Keyword.fetch!(opts, :id)

    child_spec = %{
      id: {Client, id},
      start: {Client, :start_link, [opts]},
      restart: :transient,
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started MCP client #{id} (pid: #{inspect(pid)})")
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("MCP client #{id} already running (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, :max_children} ->
        limit = CodePuppyControl.Runtime.Limits.max_mcp_clients()

        Logger.warning(
          "MCP client supervisor at capacity (limit: #{limit}). " <>
            "Refusing to start client #{id}."
        )

        :telemetry.execute(
          [:code_puppy, :supervisor, :full],
          %{count: 1},
          %{supervisor: :mcp_client, id: id}
        )

        {:error, :max_children}

      {:error, reason} = error ->
        Logger.error("Failed to start MCP client #{id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops an MCP client by id.

  Returns `:ok` on success or `{:error, :not_found}` if not found.
  """
  @spec stop_client(String.t()) :: :ok | {:error, :not_found}
  def stop_client(id) do
    case Registry.lookup(CodePuppyControl.MCP.ClientRegistry, id) do
      [] ->
        {:error, :not_found}

      [{pid, _value} | _] ->
        # Stop the GenServer gracefully
        Client.stop(id)
        # Also try to terminate under the supervisor (no-op if not supervised)
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end
    end
  end

  @doc "Lists all running MCP client IDs."
  @spec list_clients() :: [String.t()]
  def list_clients do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, [Client]} when is_pid(pid) ->
        case Registry.keys(CodePuppyControl.MCP.ClientRegistry, pid) do
          [id | _] -> [id]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc "Returns the number of active MCP clients."
  @spec client_count() :: non_neg_integer()
  def client_count do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(__MODULE__).workers
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60,
      max_children: CodePuppyControl.Runtime.Limits.max_mcp_clients()
    )
  end
end
