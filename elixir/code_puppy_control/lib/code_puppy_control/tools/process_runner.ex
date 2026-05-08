defmodule CodePuppyControl.Tools.ProcessRunner do
  @moduledoc """
  Long-running process registry and management tools.

  Provides tools for managing background processes spawned via
  `CodePuppyControl.Tools.CommandRunner`. Tracks process lifecycle,
  enables status queries, and supports kill operations.

  ## Design

  This module is a thin tool layer over `CommandRunner.ProcessManager`
  which already handles the actual process tracking. The tools here
  expose process management capabilities to the agent.

  ## Tools Provided

  - `list_processes` — List all running/managed processes
  - `kill_process` — Kill a specific process by PID
  - `kill_all_processes` — Kill all running processes

  Note: The primary command execution tool is `CommandRunner`. This module
  is specifically for process lifecycle management.
  """

  require Logger

  alias CodePuppyControl.Tool.Registry

  defmodule ListProcesses do
    @moduledoc "List all running/managed shell processes."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :list_processes

    @impl true
    def description do
      "List all currently running shell processes. " <>
        "Returns process IDs, commands, and running time."
    end

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}, "required" => []}
    end

    @impl true
    def invoke(_args, _context) do
      count = CodePuppyControl.Tools.CommandRunner.running_count()

      {:ok,
       %{
         running_count: count,
         # ProcessManager doesn't expose listing yet
         processes: []
       }}
    end
  end

  defmodule KillProcess do
    @moduledoc "Kill a specific process by OS PID."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :kill_process

    @impl true
    def description do
      "Kill a specific running process by its OS PID (process ID)."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "pid" => %{
            "type" => "integer",
            "description" => "OS process ID to kill"
          }
        },
        "required" => ["pid"]
      }
    end

    @impl true
    def invoke(args, _context) do
      pid = Map.get(args, "pid")

      case CodePuppyControl.Tools.CommandRunner.kill_process(pid) do
        :ok ->
          {:ok, %{success: true, pid: pid, message: "Process #{pid} killed"}}

        {:error, reason} ->
          {:error, %{success: false, pid: pid, message: reason}}
      end
    end
  end

  defmodule KillAllProcesses do
    @moduledoc "Kill all running shell processes."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :kill_all_processes

    @impl true
    def description do
      "Kill all currently running shell processes. " <>
        "Returns the count of processes killed."
    end

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}, "required" => []}
    end

    @impl true
    def invoke(_args, _context) do
      count = CodePuppyControl.Tools.CommandRunner.kill_all()
      {:ok, %{killed: count}}
    end
  end

  @doc """
  Registers all process runner tools with the Tool Registry.
  """
  @spec register_all() :: {:ok, non_neg_integer()}
  def register_all do
    modules = [ListProcesses, KillProcess, KillAllProcesses]

    Enum.reduce(modules, {:ok, 0}, fn module, {:ok, acc} ->
      case Registry.register(module) do
        :ok -> {:ok, acc + 1}
        {:error, _} -> {:ok, acc}
      end
    end)
  end
end
