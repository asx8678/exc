defmodule CodePuppyControl.Scheduler.Task do
  @moduledoc """
  Ecto schema for scheduled tasks.

  Represents a task that can be executed on a schedule (cron expression,
  interval, hourly, or daily). Tasks are persisted to the database and
  executed via Oban workers.

  ## Fields

    * `:name` - Unique task name (required)
    * `:description` - Optional description
    * `:agent_name` - Agent to execute the task with (required)
    * `:model` - Optional model override
    * `:prompt` - The prompt to execute (required)
    * `:config` - Additional configuration as a map
    * `:schedule` - Cron expression for cron-type schedules
    * `:schedule_type` - "interval", "hourly", "daily", or "cron"
    * `:schedule_value` - Value for interval (e.g., "30m", "1h")
    * `:enabled` - Whether the task is active
    * `:last_run_at` - When the task last executed
    * `:last_status` - "success", "failed", "running", or nil
    * `:last_exit_code` - Exit code from last run
    * `:last_error` - Error message from last failed run
    * `:run_count` - Total number of executions
    * `:working_directory` - Working directory for task execution
    * `:log_file` - Optional path to log file
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schedule_types ["interval", "hourly", "daily", "cron", "one_shot"]

  schema "scheduled_tasks" do
    field(:name, :string)
    field(:description, :string)
    field(:agent_name, :string)
    field(:model, :string)
    field(:prompt, :string)
    field(:config, :map, default: %{})
    field(:schedule, :string)
    field(:schedule_type, :string, default: "interval")
    field(:schedule_value, :string, default: "1h")
    field(:enabled, :boolean, default: true)
    field(:last_run_at, :utc_datetime)
    field(:last_status, :string)
    field(:last_exit_code, :integer)
    field(:last_error, :string)
    field(:run_count, :integer, default: 0)
    field(:working_directory, :string, default: ".")
    field(:log_file, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          description: String.t() | nil,
          agent_name: String.t(),
          model: String.t() | nil,
          prompt: String.t(),
          config: map(),
          schedule: String.t() | nil,
          schedule_type: String.t(),
          schedule_value: String.t(),
          enabled: boolean(),
          last_run_at: DateTime.t() | nil,
          last_status: String.t() | nil,
          last_exit_code: integer() | nil,
          last_error: String.t() | nil,
          run_count: integer(),
          working_directory: String.t(),
          log_file: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates a changeset for a scheduled task.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :name,
      :description,
      :agent_name,
      :model,
      :prompt,
      :config,
      :schedule,
      :schedule_type,
      :schedule_value,
      :enabled,
      :working_directory,
      :log_file
    ])
    |> validate_required([:name, :agent_name, :prompt])
    |> validate_length(:name, max: 255)
    |> validate_inclusion(:schedule_type, @schedule_types)
    |> unique_constraint(:name)
    |> validate_schedule()
  end

  @doc """
  Validates the schedule configuration based on schedule_type.
  """
  @spec validate_schedule(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_schedule(changeset) do
    case get_field(changeset, :schedule_type) do
      "cron" -> validate_cron_schedule(changeset)
      "interval" -> validate_interval_schedule(changeset)
      "one_shot" -> changeset
      _ -> changeset
    end
  end

  defp validate_cron_schedule(changeset) do
    schedule = get_field(changeset, :schedule)

    if is_nil(schedule) or schedule == "" do
      add_error(changeset, :schedule, "cron schedule_type requires a schedule value")
    else
      # Try to parse the cron expression
      case Crontab.CronExpression.Parser.parse(schedule) do
        {:ok, _} ->
          changeset

        {:error, reason} ->
          add_error(changeset, :schedule, "invalid cron expression: #{to_string(reason)}")
      end
    end
  end

  defp validate_interval_schedule(changeset) do
    value = get_field(changeset, :schedule_value)

    if is_nil(value) or value == "" do
      add_error(changeset, :schedule_value, "interval schedule_type requires a schedule_value")
    else
      case parse_interval(value) do
        {:ok, _} -> changeset
        {:error, reason} -> add_error(changeset, :schedule_value, reason)
      end
    end
  end

  @doc """
  Parses an interval string like "30m", "1h", "2d" into a duration in seconds.

  ## Examples

      iex> Task.parse_interval("30m")
      {:ok, 1800}

      iex> Task.parse_interval("1h")
      {:ok, 3600}

      iex> Task.parse_interval("invalid")
      {:error, "invalid interval format"}
  """
  @spec parse_interval(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_interval(interval_str) when is_binary(interval_str) do
    case Regex.run(~r/^(\d+)([smhd])$/i, String.trim(interval_str)) do
      [_, value_str, unit] ->
        value = String.to_integer(value_str)

        seconds =
          case String.downcase(unit) do
            "s" -> value
            "m" -> value * 60
            "h" -> value * 60 * 60
            "d" -> value * 24 * 60 * 60
          end

        {:ok, seconds}

      _ ->
        {:error,
         "invalid interval format, expected \"<number><unit>\" where unit is s, m, h, or d\""}
    end
  end

  @doc """
  Determines if a task should run based on its schedule and last run time.

  ## Examples

      iex> task = %Task{schedule_type: "interval", schedule_value: "1h", last_run_at: nil}
      iex> Task.should_run?(task, DateTime.utc_now())
      true
  """
  @spec should_run?(t(), DateTime.t()) :: boolean()
  def should_run?(task, now \\ DateTime.utc_now())

  # Disabled tasks never run — must be checked before last_run_at: nil
  def should_run?(%__MODULE__{enabled: false}, _now), do: false

  # Never run before - should run now
  def should_run?(%__MODULE__{last_run_at: nil}, _now), do: true

  # One-shot tasks that have already run should not run again
  def should_run?(%__MODULE__{schedule_type: "one_shot", last_run_at: last_run}, _now)
      when not is_nil(last_run),
      do: false

  # Interval-based scheduling
  def should_run?(
        %__MODULE__{
          schedule_type: "interval",
          schedule_value: value,
          last_run_at: last_run
        },
        now
      )
      when not is_nil(last_run) do
    case parse_interval(value) do
      {:ok, interval_seconds} ->
        last_run_unix = DateTime.to_unix(last_run, :second)
        now_unix = DateTime.to_unix(now, :second)
        now_unix - last_run_unix >= interval_seconds

      _ ->
        false
    end
  end

  # Hourly scheduling
  def should_run?(
        %__MODULE__{schedule_type: "hourly", last_run_at: last_run},
        now
      )
      when not is_nil(last_run) do
    last_run_unix = DateTime.to_unix(last_run, :second)
    now_unix = DateTime.to_unix(now, :second)
    now_unix - last_run_unix >= 3600
  end

  # Daily scheduling
  def should_run?(
        %__MODULE__{schedule_type: "daily", last_run_at: last_run},
        now
      )
      when not is_nil(last_run) do
    last_run_unix = DateTime.to_unix(last_run, :second)
    now_unix = DateTime.to_unix(now, :second)
    now_unix - last_run_unix >= 86_400
  end

  # Cron-based scheduling
  def should_run?(
        %__MODULE__{
          schedule_type: "cron",
          schedule: schedule,
          last_run_at: last_run
        },
        now
      )
      when not is_nil(last_run) and not is_nil(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, cron} ->
        # Get the next run time after the last run
        next_run = Crontab.Scheduler.get_next_run_date(cron, NaiveDateTime.to_erl(last_run))

        case next_run do
          {:ok, naive_next} ->
            next_dt = DateTime.from_naive!(naive_next, "Etc/UTC")
            DateTime.compare(next_dt, now) != :gt

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # Default: don't run if we can't determine
  def should_run?(_task, _now), do: false
end
