defmodule CodePuppyControl.Plugins.Scheduler do
  @moduledoc """
  Scheduler plugin providing `/scheduler`, `/sched`, `/cron` slash commands.

  Wraps the existing `CodePuppyControl.Scheduler` module, providing
  command-line access to scheduler operations via slash commands.

  ## Hooks Registered

    * `:custom_command` - handles `/scheduler`, `/sched`, `/cron` commands
    * `:custom_command_help` - provides help entries for scheduler commands
  """

  use CodePuppyControl.Plugins.PluginBehaviour
  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Scheduler
  require Logger

  @command_name "scheduler"
  @aliases ["sched", "cron"]

  @impl true
  def name, do: "scheduler"

  @impl true
  def description, do: "Manage scheduled tasks - create, run, and monitor automated prompts"

  @impl true
  def register do
    Callbacks.register(:custom_command, &__MODULE__.handle_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.command_help/0)
    :ok
  end

  @impl true
  def startup, do: :ok

  @impl true
  def shutdown, do: :ok

  @spec handle_command(String.t(), String.t()) :: String.t() | true | nil
  def handle_command(command, name) when name in [@command_name | @aliases] do
    tokens = String.split(command, ~r/\s+/)

    case tokens do
      [_cmd] -> show_status_overview()
      [_cmd, subcommand | rest] -> handle_subcommand(subcommand, rest)
      _ -> show_status_overview()
    end
  end

  def handle_command(_command, _name), do: nil

  defp handle_subcommand(subcommand, args) do
    case String.downcase(subcommand) do
      "start" ->
        handle_start()

      "stop" ->
        handle_stop()

      "status" ->
        handle_status()

      "list" ->
        handle_list()

      "run" ->
        handle_run(args)

      _ ->
        "Unknown subcommand: #{subcommand}\nUsage: /scheduler [start|stop|status|list|run <id>]"
    end
  end

  defp show_status_overview do
    stats = safe_scheduler_stats()

    lines = [
      "**Scheduler Status**",
      "",
      "  Total tasks: #{stats.total}",
      "  Enabled: #{stats.enabled}",
      "  Disabled: #{stats.disabled}",
      "",
      "Use /scheduler list to see all tasks",
      "Use /scheduler run <id> to run a task immediately"
    ]

    Enum.join(lines, "\n")
  end

  defp handle_start do
    case Scheduler.force_check() do
      :ok ->
        "Scheduler check triggered - enabled tasks will execute on schedule"

      {:error, :not_running} ->
        "Scheduler is not running - check skipped. Scheduled tasks are persisted but will not execute until the scheduler starts."
    end
  end

  defp handle_stop do
    "Scheduler daemon management is handled by the application supervisor"
  end

  defp handle_status do
    try do
      state = Scheduler.scheduler_status()
      format_scheduler_state(state)
    rescue
      e -> "Failed to get scheduler status: #{Exception.message(e)}"
    end
  end

  defp handle_list do
    try do
      tasks = Scheduler.list_tasks()

      if tasks == [] do
        "No scheduled tasks found. Create tasks via the database or API."
      else
        lines = ["**Scheduled Tasks**", ""]

        task_lines =
          Enum.map(tasks, fn task ->
            status = if task.enabled, do: "ON", else: "OFF"
            schedule = task.schedule || task.schedule_type || "manual"
            "  [#{task.id}] #{task.name} (#{status}, #{schedule})"
          end)

        Enum.join(lines ++ task_lines, "\n")
      end
    rescue
      e -> "Failed to list tasks: #{Exception.message(e)}"
    end
  end

  defp handle_run([]) do
    "Usage: /scheduler run <task_id>"
  end

  defp handle_run([id_str | _]) do
    case Integer.parse(id_str) do
      {id, ""} ->
        try do
          case Scheduler.run_task_now(id) do
            {:ok, _job} -> "Task #{id} triggered successfully"
            {:error, :not_found} -> "Task #{id} not found"
            {:error, reason} -> "Failed to run task #{id}: #{inspect(reason)}"
          end
        rescue
          e -> "Failed to run task: #{Exception.message(e)}"
        end

      :error ->
        "Invalid task ID: #{id_str}. Must be an integer."
    end
  end

  defp format_scheduler_state(state) when is_map(state) do
    lines = ["**Scheduler State**", ""]

    lines =
      Enum.reduce(state, lines, fn {key, value}, acc ->
        acc ++ ["  #{key}: #{inspect(value)}"]
      end)

    Enum.join(lines, "\n")
  end

  defp format_scheduler_state(state) do
    "**Scheduler State**: #{inspect(state)}"
  end

  defp safe_scheduler_stats do
    try do
      stats = Scheduler.statistics()
      %{total: stats.total, enabled: stats.enabled, disabled: stats.disabled}
    rescue
      _ -> %{total: 0, enabled: 0, disabled: 0}
    end
  end

  @spec command_help() :: [{String.t(), String.t()}]
  def command_help do
    [
      {"/scheduler", "Manage scheduled tasks - launch UI or use sub-commands"},
      {"/sched", "Alias for /scheduler"},
      {"/cron", "Alias for /scheduler"}
    ]
  end
end
