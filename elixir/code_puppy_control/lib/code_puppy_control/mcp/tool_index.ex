defmodule CodePuppyControl.MCP.ToolIndex do
  @moduledoc """
  Registry of connected MCP servers and their tools.

  This module provides an ETS-backed index for fast tool discovery — finding
  which MCP server provides a given tool.

  ## Architecture

  - **ETS table**: `:mcp_tool_index` stores `{tool_name, server_id}` mappings
    for O(1) tool-to-server lookup

  ## Usage

      # Find which server provides a tool
      {:ok, server_id} = MCP.ToolIndex.find_server_for_tool("read_file")

      # List all tools across all servers
      tools = MCP.ToolIndex.list_all_tools()

      # Get tools for a specific server
      tools = MCP.ToolIndex.get_tools("filesystem")

  ## ETS Table Format

  The ETS table uses two types of entries:

    * `{{:tool, tool_name}, server_id}` — tool → server mapping
    * `{{:server, server_id}, tools_list}` — server → tools mapping
  """

  use GenServer

  require Logger

  @table :mcp_tool_index

  @doc "Starts the ToolIndex GenServer and creates the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Registers tools for a given server.

  Removes any previously registered tools for the same server before
  inserting the new set.
  """
  @spec register_tools(String.t(), [map()]) :: :ok
  def register_tools(server_id, tools) do
    GenServer.call(__MODULE__, {:register_tools, server_id, tools})
  end

  @doc """
  Removes all tool entries for a server.
  """
  @spec unregister_server(String.t()) :: :ok
  def unregister_server(server_id) do
    GenServer.call(__MODULE__, {:unregister_server, server_id})
  end

  @doc """
  Finds the server ID that provides the given tool.

  Returns `{:ok, server_id}` or `:error` if no server provides the tool.
  If multiple servers provide the same tool, returns the first one found.
  """
  @spec find_server_for_tool(String.t()) :: {:ok, String.t()} | :error
  def find_server_for_tool(tool_name) do
    case :ets.lookup(@table, {:tool, tool_name}) do
      [{{:tool, ^tool_name}, server_id}] -> {:ok, server_id}
      [] -> :error
    end
  end

  @doc """
  Lists all tools across all servers.

  Returns a list of `{tool_name, server_id}` tuples.
  """
  @spec list_all_tools() :: [{String.t(), String.t()}]
  def list_all_tools do
    :ets.match_object(@table, {{:tool, :_}, :_})
    |> Enum.map(fn {{:tool, tool_name}, server_id} -> {tool_name, server_id} end)
  end

  @doc """
  Gets the tools registered for a specific server.

  Returns a list of tool maps.
  """
  @spec get_tools(String.t()) :: [map()]
  def get_tools(server_id) do
    case :ets.lookup(@table, {:server, server_id}) do
      [{{:server, ^server_id}, tools}] -> tools
      [] -> []
    end
  end

  @doc """
  Returns a map of server_id → tool count.
  """
  @spec server_summary() :: %{String.t() => non_neg_integer()}
  def server_summary do
    :ets.match_object(@table, {{:server, :_}, :_})
    |> Enum.map(fn {{:server, server_id}, tools} -> {server_id, length(tools)} end)
    |> Map.new()
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register_tools, server_id, tools}, _from, state) do
    # Remove old tools for this server
    unregister_server_tools(server_id)

    # Insert new tool mappings
    Enum.each(tools, fn tool ->
      tool_name = Map.get(tool, "name", Map.get(tool, :name))

      if tool_name do
        :ets.insert(@table, {{:tool, tool_name}, server_id})
      end
    end)

    # Store the full tool list for the server
    :ets.insert(@table, {{:server, server_id}, tools})

    Logger.debug("MCP ToolIndex: registered #{length(tools)} tools for #{server_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister_server, server_id}, _from, state) do
    unregister_server_tools(server_id)
    :ets.delete(@table, {:server, server_id})
    {:reply, :ok, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp unregister_server_tools(server_id) do
    # Get current tools for this server and remove them
    case :ets.lookup(@table, {:server, server_id}) do
      [{{:server, ^server_id}, tools}] ->
        Enum.each(tools, fn tool ->
          tool_name = Map.get(tool, "name", Map.get(tool, :name))

          if tool_name do
            :ets.delete(@table, {:tool, tool_name})
          end
        end)

      [] ->
        :ok
    end
  end
end
