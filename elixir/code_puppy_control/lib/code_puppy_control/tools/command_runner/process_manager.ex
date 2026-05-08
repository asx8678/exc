defmodule CodePuppyControl.Tools.CommandRunner.ProcessManager do
  @moduledoc """
  Process tracking and lifecycle management for shell commands.

  This GenServer tracks running shell commands and provides:
  - Command registration/unregistration with OS PID tracking
  - Kill escalation (SIGTERM → SIGINT → SIGKILL) for process groups
  - Bulk process killing with parallelized signaling
  - Bounded set of user-killed PIDs (prevent unbounded growth)
  - Process group awareness (POSIX process groups)

  ## Architecture

  Each registered command stores:
  - `id` - Unique tracking ID (monotonic counter)
  - `command` - The shell command string
  - `os_pid` - The OS process ID (when available)
  - `started_at` - Monotonic timestamp for timeout tracking
  - `mode` - `:standard` | `:pty` | `:background`

  ## Kill Escalation

  On POSIX, follows the Python _kill_process_group pattern:
  1. SIGTERM to process group → wait 1s
  2. SIGINT to process group → wait 0.6s
  3. SIGKILL to process group → wait 0.5s
  4. Direct SIGKILL × 3 attempts → 0.1s each

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  use GenServer

  require Logger

  defstruct commands: %{}, counter: 0, killed_pids: %{}, killed_pids_max: 1024

  @typedoc """
  Command tracking information.
  """
  @type command_info :: %{
          command: String.t(),
          os_pid: non_neg_integer() | nil,
          started_at: integer(),
          id: non_neg_integer(),
          mode: :standard | :pty | :background
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the ProcessManager GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a command that is about to be executed.

  Returns `{:ok, id}` with a tracking ID for the command.

  ## Options

  - `:os_pid` - The OS process ID (may be nil if not yet known)
  - `:mode` - Execution mode (`:standard`, `:pty`, `:background`)
  """
  @spec register_command(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def register_command(command, opts \\ []) do
    GenServer.call(__MODULE__, {:register, command, opts})
  end

  @doc """
  Updates the OS PID for a previously registered command.

  Called after the process is spawned when the PID becomes known.
  """
  @spec update_os_pid(non_neg_integer(), non_neg_integer()) :: :ok | {:error, :not_found}
  def update_os_pid(tracking_id, os_pid) do
    GenServer.call(__MODULE__, {:update_os_pid, tracking_id, os_pid})
  end

  @doc """
  Unregisters a command that has completed.
  """
  @spec unregister_command(non_neg_integer()) :: :ok
  def unregister_command(id) do
    GenServer.call(__MODULE__, {:unregister, id})
  end

  @doc """
  Kills all running shell processes (best-effort with escalation).

  Returns the count of processes signaled.
  """
  @spec kill_all() :: non_neg_integer()
  def kill_all do
    GenServer.call(__MODULE__, :kill_all)
  end

  @doc """
  Returns the count of currently running commands.
  """
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @doc """
  Kills a specific process by its OS PID using escalation.

  Returns `:ok` if the process was signaled, `{:error, reason}` otherwise.
  """
  @spec kill_process(non_neg_integer()) :: :ok | {:error, String.t()}
  def kill_process(os_pid) when is_integer(os_pid) do
    GenServer.call(__MODULE__, {:kill_process, os_pid})
  end

  @doc """
  Returns whether a PID is in the user-killed set.

  This tracks processes killed by user action (Ctrl-C/Ctrl-X)
  so the result can include `user_interrupted: true`.
  """
  @spec is_pid_killed?(non_neg_integer()) :: boolean()
  def is_pid_killed?(os_pid) when is_integer(os_pid) do
    GenServer.call(__MODULE__, {:is_pid_killed, os_pid})
  end

  @doc """
  Returns the list of currently tracked commands.
  """
  @spec list_commands() :: [command_info()]
  def list_commands do
    GenServer.call(__MODULE__, :list_commands)
  end

  @doc """
  Returns the command info for a tracking ID.
  """
  @spec get_command(non_neg_integer()) :: command_info() | nil
  def get_command(tracking_id) do
    GenServer.call(__MODULE__, {:get_command, tracking_id})
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      commands: %{},
      counter: 0,
      killed_pids: %{},
      killed_pids_max: 1024
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, command, opts}, _from, state) do
    id = state.counter + 1
    os_pid = Keyword.get(opts, :os_pid)
    mode = Keyword.get(opts, :mode, :standard)

    info = %{
      command: command,
      os_pid: os_pid,
      started_at: System.monotonic_time(:millisecond),
      id: id,
      mode: mode
    }

    new_commands = Map.put(state.commands, id, info)
    {:reply, {:ok, id}, %{state | commands: new_commands, counter: id}}
  end

  @impl true
  def handle_call({:update_os_pid, tracking_id, os_pid}, _from, state) do
    case Map.get(state.commands, tracking_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      info ->
        updated = Map.put(info, :os_pid, os_pid)
        new_commands = Map.put(state.commands, tracking_id, updated)
        {:reply, :ok, %{state | commands: new_commands}}
    end
  end

  @impl true
  def handle_call({:unregister, id}, _from, state) do
    new_commands = Map.delete(state.commands, id)
    {:reply, :ok, %{state | commands: new_commands}}
  end

  @impl true
  def handle_call(:kill_all, _from, state) do
    count = map_size(state.commands)

    # Parallelized kill of all tracked processes
    new_killed =
      state.commands
      |> Enum.filter(fn {_id, info} -> info.os_pid != nil end)
      |> Enum.reduce(state.killed_pids, fn {_id, info}, killed ->
        kill_process_group(info.os_pid)
        add_killed_pid(killed, info.os_pid, state.killed_pids_max)
      end)

    {:reply, count, %{state | commands: %{}, killed_pids: new_killed}}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, map_size(state.commands), state}
  end

  @impl true
  def handle_call({:kill_process, os_pid}, _from, state) do
    _result = kill_process_group(os_pid)

    new_killed = add_killed_pid(state.killed_pids, os_pid, state.killed_pids_max)

    {:reply, :ok, %{state | killed_pids: new_killed}}
  end

  @impl true
  def handle_call({:is_pid_killed, os_pid}, _from, state) do
    {:reply, Map.has_key?(state.killed_pids, os_pid), state}
  end

  @impl true
  def handle_call(:list_commands, _from, state) do
    {:reply, Map.values(state.commands), state}
  end

  @impl true
  def handle_call({:get_command, tracking_id}, _from, state) do
    {:reply, Map.get(state.commands, tracking_id), state}
  end

  # ---------------------------------------------------------------------------
  # Kill Escalation (POSIX process group handling)
  # ---------------------------------------------------------------------------

  @spec kill_process_group(non_neg_integer()) :: :ok | {:error, String.t()}
  defp kill_process_group(pid) do
    if windows?() do
      kill_windows(pid)
    else
      kill_posix(pid)
    end
  end

  # POSIX: SIGTERM → SIGINT → SIGKILL escalation
  defp kill_posix(pid) do
    try do
      # Try process group kill first
      pgid = getpgid(pid)

      if pgid && pgid > 0 do
        # Step 1: SIGTERM to process group
        kill_pgid(pgid, :sigterm)
        if wait_dead(pid, 1000), do: throw(:done)

        # Step 2: SIGINT to process group
        kill_pgid(pgid, :sigint)
        if wait_dead(pid, 600), do: throw(:done)

        # Step 3: SIGKILL to process group
        kill_pgid(pgid, :sigkill)
        if wait_dead(pid, 500), do: throw(:done)
      end

      # Direct kill attempts (last resort)
      direct_kill(pid)
    catch
      :done -> :ok
    end
  end

  defp kill_windows(pid) do
    # On Windows, use taskkill for tree kill
    try do
      System.cmd("taskkill", ["/F", "/T", "/PID", to_string(pid)],
        stderr_to_stdout: true,
        parallelism: true
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # Fallback: try direct OS kill
    try do
      :os.cmd(String.to_charlist("kill -9 #{pid}"))
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp direct_kill(pid) do
    try do
      for _ <- 1..3 do
        kill_pid(pid, :sigkill)
        if wait_dead(pid, 100), do: throw(:done)
      end

      :ok
    catch
      :done -> :ok
    end
  end

  # Send signal to a process group
  defp kill_pgid(pgid, signal) do
    sig_num = signal_to_int(signal)

    try do
      :os.cmd(String.to_charlist("kill -#{sig_num} -#{pgid}"))
    catch
      _, _ -> :ok
    end
  end

  # Send signal directly to a PID
  defp kill_pid(pid, signal) do
    sig_num = signal_to_int(signal)

    try do
      :os.cmd(String.to_charlist("kill -#{sig_num} #{pid}"))
    catch
      _, _ -> :ok
    end
  end

  # Check if a process is dead by checking if /proc/<pid> exists or `kill -0`
  defp wait_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_dead_loop(pid, deadline)
  end

  defp wait_dead_loop(pid, deadline) do
    if process_alive?(pid) do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        wait_dead_loop(pid, deadline)
      else
        false
      end
    else
      true
    end
  end

  defp process_alive?(pid) do
    try do
      # kill -0 checks if process exists without sending a signal
      {_output, exit_code} =
        System.cmd("kill", ["-0", to_string(pid)],
          stderr_to_stdout: true,
          parallelism: true
        )

      exit_code == 0
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  # Get process group ID
  defp getpgid(pid) do
    try do
      {output, 0} =
        System.cmd("ps", ["-o", "pgid=", "-p", to_string(pid)], parallelism: true)

      output
      |> String.trim()
      |> String.to_integer()
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp signal_to_int(:sigterm), do: 15
  defp signal_to_int(:sigint), do: 2
  defp signal_to_int(:sigkill), do: 9

  defp windows? do
    case :os.type() do
      {:win32, _} -> true
      _ -> false
    end
  end

  # Bounded killed-PID set (dict as ordered set, max 1024 entries)
  defp add_killed_pid(killed, os_pid, max) do
    killed
    |> Map.put(os_pid, nil)
    |> maybe_trim_killed(max)
  end

  defp maybe_trim_killed(killed, max) when map_size(killed) > max do
    # Remove oldest entry (first key)
    {oldest, _} = Enum.at(killed, 0)
    Map.delete(killed, oldest)
  end

  defp maybe_trim_killed(killed, _max), do: killed
end
