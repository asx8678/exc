defmodule CodePuppyControl.Agents.SchedulerAgent do
  @moduledoc """
  The Scheduler Agent — manages scheduled Code Puppy tasks.

  Scheduler Agent helps users create, manage, and monitor scheduled tasks
  that run automatically. It supports creating recurring prompts, checking
  scheduler status, viewing execution logs, and managing task lifecycle.

  ## Focus Areas

    * **Task creation** — set up prompts that run on schedules (interval, hourly, daily)
    * **Scheduler management** — check status, force immediate evaluation
    * **Task monitoring** — view logs, check last run status, inspect history
    * **Task lifecycle** — enable/disable, run immediately, delete tasks

  ## Tool Access

    * `cp_read_file` — examine configuration files for context
    * `cp_list_files` — explore project directory structure
    * `cp_grep` — search for relevant patterns
    * `cp_ask_user_question` — ask clarifying questions interactively
    * `cp_scheduler_list_tasks` — list all scheduled tasks
    * `cp_scheduler_create_task` — create a new scheduled task
    * `cp_scheduler_delete_task` — delete a task by ID or name
    * `cp_scheduler_toggle_task` — toggle task enabled/disabled
    * `cp_scheduler_status` — check scheduler status
    * `cp_scheduler_run_task` — run a task immediately
    * `cp_scheduler_view_log` — view execution history for a task
    * `cp_scheduler_force_check` — force immediate schedule evaluation

  ## Architecture Note

  The Elixir scheduler runs as a supervised GenServer (`CronScheduler`)
  under the application supervision tree. There is no separate daemon
  process to start or stop — it's always available when the application
  is running.

  ## Model

  Defaults to `claude-sonnet-4-20250514` for strong reasoning and scheduling.
  """

  use CodePuppyControl.Agent.Behaviour

  # ── Callbacks ─────────────────────────────────────────────────────────────

  @impl true
  @spec name() :: :scheduler_agent
  def name, do: :scheduler_agent

  @impl true
  @spec display_name() :: String.t()
  def display_name, do: "Scheduler Agent 📅"

  @impl true
  @spec description() :: String.t()
  def description,
    do:
      "Helps you create and manage scheduled tasks — automate code reviews, " <>
        "daily reports, and more. Can check scheduler status, view logs, " <>
        "and walk you through setting up new scheduled prompts."

  @impl true
  @spec get_system_prompt() :: String.t()
  def get_system_prompt do
    system_prompt(%{})
  end

  @impl true
  @spec system_prompt(CodePuppyControl.Agent.Behaviour.context()) :: String.t()
  def system_prompt(_context) do
    """
    You are the Scheduler Agent 📅, a friendly assistant that helps users automate Code Puppy tasks.

    ## Your Capabilities

    You can help users:
    1. **Create scheduled tasks** — set up prompts that run automatically (every hour, daily, etc.)
    2. **Check scheduler status** — see if the scheduler is running and healthy
    3. **Monitor tasks** — check status, view logs, see what's running
    4. **Edit/delete tasks** — modify or remove existing schedules
    5. **Force checks** — trigger immediate schedule evaluation

    ## How Scheduling Works

    - The scheduler runs as a supervised GenServer under the application
    - Tasks are stored in the database
    - Each task runs with a configured agent and model
    - Output is saved to execution logs

    ## Schedule Types

    - **interval**: Run every X time (e.g., "30m", "2h", "1d")
    - **hourly**: Run once per hour
    - **daily**: Run once per day

    ## Available Agents to Suggest

    When users ask about automation, suggest appropriate agents:
    - `code_puppy` — general coding tasks
    - `code_reviewer` or `python_reviewer` — code review tasks
    - `security_auditor` — security scanning
    - `qa_expert` — quality assurance checks
    - `planning_agent` — planning and documentation

    ## Best Practices to Suggest

    1. **For code reviews**: daily or on-demand
    2. **For reports/summaries**: daily or weekly
    3. **For monitoring**: hourly or every few hours

    ## Interaction Style

    - Be conversational and helpful
    - Ask clarifying questions to understand what the user wants to automate
    - Suggest good prompts based on the task type
    - Recommend appropriate agents and schedules
    - Always confirm before creating tasks
    - When listing tasks, always call `cp_scheduler_list_tasks` first

    ## IMPORTANT: Always Start by Checking Status

    When a user wants to work with schedules, ALWAYS start by calling
    `cp_scheduler_list_tasks` to see the current state of things. This shows:
    - Whether the scheduler is running
    - What tasks exist
    - Their status and last run info

    ## Tool Reference

    - `cp_scheduler_list_tasks` — see all scheduled tasks and scheduler status
    - `cp_scheduler_create_task` — create a new task with schedule configuration
    - `cp_scheduler_delete_task` — remove a task by ID or name
    - `cp_scheduler_toggle_task` — enable/disable a task
    - `cp_scheduler_status` — check if the scheduler is running
    - `cp_scheduler_run_task` — run a task immediately
    - `cp_scheduler_view_log` — view a task's execution history
    - `cp_scheduler_force_check` — force immediate schedule evaluation
    """
  end

  @impl true
  @spec allowed_tools() :: [atom()]
  def allowed_tools do
    [
      # Standard file tools for context
      :cp_list_files,
      :cp_read_file,
      :cp_grep,
      # User interaction
      :cp_ask_user_question,
      # Scheduler-specific tools
      :cp_scheduler_list_tasks,
      :cp_scheduler_create_task,
      :cp_scheduler_delete_task,
      :cp_scheduler_toggle_task,
      :cp_scheduler_status,
      :cp_scheduler_run_task,
      :cp_scheduler_view_log,
      :cp_scheduler_force_check
    ]
  end

  @impl true
  @spec model_preference() :: String.t()
  def model_preference, do: "claude-sonnet-4-20250514"
end
