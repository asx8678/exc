defmodule CodePuppyControl.CLI.SlashCommands.Commands.MCPLifecycle do
  @moduledoc """
  Lifecycle subcommand handlers and formatters for the /mcp command.

  Extracted from `MCP` to keep the main module under the 600-line cap.
  This module owns:

  - Start/stop/restart/start-all/stop-all IO dispatchers
  - Pure formatting functions for lifecycle results

  The main `MCP` module delegates lifecycle subcommands here.
  """

  alias CodePuppyControl.MCP.Manager

  # ── Subcommand: start ──────────────────────────────────────────────────

  @doc """
  IO dispatcher for `/mcp start <name>`.
  """
  @spec show_start(String.t()) :: :ok
  def show_start(name) do
    result =
      if mcp_supervisor_running?() do
        try do
          Manager.start_server_by_name(name)
        rescue
          _ -> {:error, :supervisor_error}
        end
      else
        {:error, :supervisor_not_running}
      end

    IO.puts("")
    IO.puts(format_start_result(name, result))
    IO.puts("")
  end

  @doc """
  IO dispatcher for `/mcp start` (no name — usage hint).
  """
  @spec show_start_usage() :: :ok
  def show_start_usage do
    IO.puts("")
    IO.puts("    #{IO.ANSI.yellow()}Usage: /mcp start <server_name>#{IO.ANSI.reset()}")
    IO.puts("    Use /mcp list to see configured servers.")
    IO.puts("")
  end

  @doc """
  Formats the result of a start operation (pure, no IO).
  """
  @spec format_start_result(
          String.t(),
          {:ok, String.t()} | {:ok, :already_running} | {:error, term()}
        ) ::
          String.t()
  def format_start_result(name, {:ok, :already_running}) do
    "    #{IO.ANSI.yellow()}• #{name} is already running#{IO.ANSI.reset()}"
  end

  def format_start_result(name, {:ok, server_id}) do
    "    #{IO.ANSI.green()}✓ Started server (#{server_id})#{IO.ANSI.reset()}\n" <>
      "    #{IO.ANSI.faint()}Use /mcp status #{name} to check initialization.#{IO.ANSI.reset()}"
  end

  def format_start_result(name, {:error, :not_configured}) do
    "    #{IO.ANSI.red()}✗ Server '#{name}' not found in configuration.#{IO.ANSI.reset()}\n" <>
      "    Use /mcp list to see configured servers."
  end

  def format_start_result(name, {:error, :supervisor_not_running}) do
    "    #{IO.ANSI.red()}✗ Cannot start '#{name}' — MCP supervisor is not running.#{IO.ANSI.reset()}"
  end

  def format_start_result(name, {:error, reason}) do
    "    #{IO.ANSI.red()}✗ Failed to start '#{name}': #{inspect(reason)}#{IO.ANSI.reset()}"
  end

  # ── Subcommand: stop ───────────────────────────────────────────────────

  @doc """
  IO dispatcher for `/mcp stop <name>`.
  """
  @spec show_stop(String.t()) :: :ok
  def show_stop(name) do
    result =
      if mcp_supervisor_running?() do
        try do
          Manager.stop_server_by_name(name)
        rescue
          _ -> {:error, :supervisor_error}
        end
      else
        {:error, :supervisor_not_running}
      end

    IO.puts("")
    IO.puts(format_stop_result(name, result))
    IO.puts("")
  end

  @doc """
  IO dispatcher for `/mcp stop` (no name — usage hint).
  """
  @spec show_stop_usage() :: :ok
  def show_stop_usage do
    IO.puts("")
    IO.puts("    #{IO.ANSI.yellow()}Usage: /mcp stop <server_name>#{IO.ANSI.reset()}")
    IO.puts("    Use /mcp status to see running servers.")
    IO.puts("")
  end

  @doc """
  Formats the result of a stop operation (pure, no IO).
  """
  @spec format_stop_result(String.t(), :ok | {:error, term()}) :: String.t()
  def format_stop_result(name, :ok) do
    "    #{IO.ANSI.green()}✓ Stopped server: #{name}#{IO.ANSI.reset()}"
  end

  def format_stop_result(name, {:error, :not_running}) do
    "    #{IO.ANSI.yellow()}• '#{name}' is not currently running#{IO.ANSI.reset()}"
  end

  def format_stop_result(name, {:error, :supervisor_not_running}) do
    "    #{IO.ANSI.red()}✗ Cannot stop '#{name}' — MCP supervisor is not running.#{IO.ANSI.reset()}"
  end

  def format_stop_result(name, {:error, reason}) do
    "    #{IO.ANSI.red()}✗ Failed to stop '#{name}': #{inspect(reason)}#{IO.ANSI.reset()}"
  end

  # ── Subcommand: restart ────────────────────────────────────────────────

  @doc """
  IO dispatcher for `/mcp restart <name>`.
  """
  @spec show_restart(String.t()) :: :ok
  def show_restart(name) do
    result =
      if mcp_supervisor_running?() do
        try do
          Manager.restart_server_by_name(name)
        rescue
          _ -> {:error, :supervisor_error}
        end
      else
        {:error, :supervisor_not_running}
      end

    IO.puts("")
    IO.puts(format_restart_result(name, result))
    IO.puts("")
  end

  @doc """
  IO dispatcher for `/mcp restart` (no name — usage hint).
  """
  @spec show_restart_usage() :: :ok
  def show_restart_usage do
    IO.puts("")
    IO.puts("    #{IO.ANSI.yellow()}Usage: /mcp restart <server_name>#{IO.ANSI.reset()}")
    IO.puts("    Use /mcp list to see configured servers.")
    IO.puts("")
  end

  @doc """
  Formats the result of a restart operation (pure, no IO).
  """
  @spec format_restart_result(String.t(), {:ok, String.t()} | {:error, term()}) :: String.t()
  def format_restart_result(name, {:ok, server_id}) do
    "    #{IO.ANSI.green()}✓ Restarted server: #{name} (#{server_id})#{IO.ANSI.reset()}"
  end

  def format_restart_result(name, {:error, :not_configured}) do
    "    #{IO.ANSI.red()}✗ Server '#{name}' not found in configuration.#{IO.ANSI.reset()}\n" <>
      "    Use /mcp list to see configured servers."
  end

  def format_restart_result(name, {:error, :supervisor_not_running}) do
    "    #{IO.ANSI.red()}✗ Cannot restart '#{name}' — MCP supervisor is not running.#{IO.ANSI.reset()}"
  end

  def format_restart_result(name, {:error, reason}) do
    "    #{IO.ANSI.red()}✗ Failed to restart '#{name}': #{inspect(reason)}#{IO.ANSI.reset()}"
  end

  # ── Subcommand: start-all ─────────────────────────────────────────────

  @doc """
  IO dispatcher for `/mcp start-all`.
  """
  @spec show_start_all() :: :ok
  def show_start_all do
    results =
      if mcp_supervisor_running?() do
        try do
          Manager.start_all_configured()
        rescue
          _ -> []
        end
      else
        []
      end

    IO.puts("")
    IO.puts(format_start_all_result(results))
    IO.puts("")
  end

  @doc """
  Formats the result of a start-all operation (pure, no IO).
  """
  @spec format_start_all_result([{String.t(), atom() | tuple()}]) :: String.t()
  def format_start_all_result([]) do
    "    #{IO.ANSI.faint()}No MCP servers configured.#{IO.ANSI.reset()}"
  end

  def format_start_all_result(results) do
    lines = ["    #{IO.ANSI.bright()}Starting all configured servers#{IO.ANSI.reset()}", ""]

    {started, already, failed} =
      Enum.reduce(results, {0, 0, 0}, fn
        {_name, {:ok, :already_running}}, {s, a, f} -> {s, a + 1, f}
        {_name, {:ok, _sid}}, {s, a, f} -> {s + 1, a, f}
        {_name, {:error, _}}, {s, a, f} -> {s, a, f + 1}
      end)

    per_server =
      Enum.map(results, fn
        {name, {:ok, :already_running}} ->
          "    #{IO.ANSI.yellow()}• #{name}: already running#{IO.ANSI.reset()}"

        {name, {:ok, _sid}} ->
          "    #{IO.ANSI.green()}✓ Started: #{name}#{IO.ANSI.reset()}"

        {name, {:error, reason}} ->
          "    #{IO.ANSI.red()}✗ #{name}: #{format_error_reason(reason)}#{IO.ANSI.reset()}"
      end)

    summary =
      [""] ++
        [
          "    #{IO.ANSI.faint()}#{started} started, #{already} already running, #{failed} failed#{IO.ANSI.reset()}"
        ]

    Enum.join(lines ++ per_server ++ summary, "\n")
  end

  # ── Subcommand: stop-all ──────────────────────────────────────────────

  @doc """
  IO dispatcher for `/mcp stop-all`.
  """
  @spec show_stop_all() :: :ok
  def show_stop_all do
    results =
      if mcp_supervisor_running?() do
        try do
          Manager.stop_all_running()
        rescue
          _ -> []
        end
      else
        []
      end

    IO.puts("")
    IO.puts(format_stop_all_result(results))
    IO.puts("")
  end

  @doc """
  Formats the result of a stop-all operation (pure, no IO).
  """
  @spec format_stop_all_result([{String.t(), :ok | {:error, term()}}]) :: String.t()
  def format_stop_all_result([]) do
    "    #{IO.ANSI.faint()}No MCP servers currently running.#{IO.ANSI.reset()}"
  end

  def format_stop_all_result(results) do
    lines = ["    #{IO.ANSI.bright()}Stopping all running servers#{IO.ANSI.reset()}", ""]

    {stopped, failed} =
      Enum.reduce(results, {0, 0}, fn
        {_name, :ok}, {s, f} -> {s + 1, f}
        {_name, {:error, _}}, {s, f} -> {s, f + 1}
      end)

    per_server =
      Enum.map(results, fn
        {name, :ok} ->
          "    #{IO.ANSI.green()}✓ Stopped: #{name}#{IO.ANSI.reset()}"

        {name, {:error, reason}} ->
          "    #{IO.ANSI.red()}✗ #{name}: #{format_error_reason(reason)}#{IO.ANSI.reset()}"
      end)

    summary =
      [""] ++
        ["    #{IO.ANSI.faint()}#{stopped} stopped, #{failed} failed#{IO.ANSI.reset()}"]

    Enum.join(lines ++ per_server ++ summary, "\n")
  end

  # ── Shared formatting helpers ─────────────────────────────────────────

  @doc """
  Formats a lifecycle error reason as a human-readable string.
  """
  @spec format_error_reason(term()) :: String.t()
  def format_error_reason(:not_configured), do: "not configured"
  def format_error_reason(:not_running), do: "not running"
  def format_error_reason(:supervisor_not_running), do: "supervisor not running"
  def format_error_reason(reason), do: inspect(reason)

  # ── Private helpers ────────────────────────────────────────────────────

  defp mcp_supervisor_running? do
    case Process.whereis(CodePuppyControl.MCP.Supervisor) do
      nil -> false
      _pid -> true
    end
  end
end
