defmodule CodePuppyControlWeb.Admin.Data do
  @moduledoc """
  Data adapter for the admin LiveView UI.

  This is the **single seam** between the admin LiveView surface and the
  CodePuppy Control runtime. LiveViews under `CodePuppyControlWeb.Admin.*`
  must call **only** functions in this module — never poke at `Run.*`,
  `Tools.*`, `Sessions`, `EventBus`, or `PackParallelism` directly.

  Why this rule exists: the admin UI is an *optional surface*. The runtime
  is authoritative. If a LiveView reaches past this adapter into runtime
  internals, it can break the runtime's invariants by accident, and worse,
  bake UI assumptions into business logic. Keep the contract narrow.

  ## What this module does

    * Reads from existing context modules (`Run.Manager`, `AgentCatalogue`,
      `Sessions`, `PackParallelism`).
    * Provides a small, curated set of mutations (pack limit, session
      deletion, scheduler control) that are safe for admin UI use. Every
      mutation is wrapped in a `rescue` to avoid crashing the LiveView.
    * Shells out to `git worktree list --porcelain` for read-only worktree
      enumeration.
    * Subscribes the calling process to the `EventBus` global topic so
      LiveViews receive runtime events as `{:event, %{}}` messages.
    * Returns plain UI-friendly maps. No structs leak through unless they
      are already public domain types (e.g. `Run.State.t()` is exposed
      because `Run.Manager.list_runs_with_details/1` already returns plain
      maps derived from it).

  ## What this module does NOT do

    * **No raw runtime access.** No `Run.*`, `Tools.*`, or direct ETS/GeneServer
      calls. All interactions go through the context modules.
    * **No business logic.** Decisions about what a "healthy" pack looks
      like, which agents are visible, etc., are made by the underlying
      modules. We just render what they tell us.
    * **No side effects on subscribe.** Subscribing is idempotent and free.
  """

  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Plugins.PackParallelism
  alias CodePuppyControl.Run
  alias CodePuppyControl.Scheduler
  alias CodePuppyControl.Sessions
  alias CodePuppyControl.Tools.{AgentCatalogue, AgentManager}

  require Logger

  @typedoc "UI-friendly job summary."
  @type job :: %{
          run_id: String.t(),
          session_id: String.t() | nil,
          agent_name: String.t() | nil,
          status: atom(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          error: term() | nil,
          metadata: map()
        }

  @typedoc "UI-friendly agent summary."
  @type agent :: %{
          name: String.t(),
          display_name: String.t(),
          description: String.t(),
          module: module() | nil,
          active_runs: non_neg_integer()
        }

  @typedoc "UI-friendly worktree row."
  @type worktree :: %{
          path: String.t(),
          branch: String.t() | nil,
          head: String.t() | nil,
          bare: boolean(),
          detached: boolean(),
          locked: boolean()
        }

  @typedoc "Pack concurrency snapshot."
  @type pack_status :: %{
          limit: non_neg_integer(),
          active: non_neg_integer(),
          waiters: non_neg_integer(),
          available: non_neg_integer()
        }

  # ── Subscriptions ─────────────────────────────────────────────────────

  @doc """
  Subscribes the calling process to the global `EventBus` event firehose.

  LiveViews call this in `mount/3` (only on the second `connected?` mount)
  to receive runtime events as `{:event, %{type: "...", ...}}` messages
  in `handle_info/2`.

  Idempotent. Returns `:ok` on success.
  """
  @spec subscribe_global_events() :: :ok | {:error, term()}
  def subscribe_global_events, do: EventBus.subscribe_global()

  @doc """
  Unsubscribes from the global event firehose. Safe to call from
  `terminate/2`.
  """
  @spec unsubscribe_global_events() :: :ok | {:error, term()}
  def unsubscribe_global_events, do: EventBus.unsubscribe_global()

  @doc """
  Subscribes to events for a specific run.
  """
  @spec subscribe_run(String.t()) :: :ok | {:error, term()}
  def subscribe_run(run_id) when is_binary(run_id), do: EventBus.subscribe_run(run_id)

  @doc """
  Unsubscribes from a specific run topic.
  """
  @spec unsubscribe_run(String.t()) :: :ok | {:error, term()}
  def unsubscribe_run(run_id) when is_binary(run_id), do: EventBus.unsubscribe_run(run_id)

  # ── Dashboard summary ─────────────────────────────────────────────────

  @doc """
  Returns the high-level dashboard summary used by `Admin.DashboardLive`.

  Aggregates counts from runs, agents, and the pack semaphore. Cheap to
  call; safe to run on every tick.
  """
  @spec dashboard_summary() :: %{
          jobs: %{
            total: non_neg_integer(),
            by_status: %{atom() => non_neg_integer()},
            recent: [job()]
          },
          agents: %{total: non_neg_integer(), with_active_runs: non_neg_integer()},
          sessions: %{total: non_neg_integer()},
          pack: pack_status(),
          worktrees: %{total: non_neg_integer()}
        }
  def dashboard_summary do
    jobs = list_jobs()
    by_status = Enum.frequencies_by(jobs, & &1.status)

    %{
      jobs: %{
        total: length(jobs),
        by_status: by_status,
        recent: jobs |> Enum.sort_by(& &1.started_at, {:desc, DateTime}) |> Enum.take(10)
      },
      agents: agents_summary(jobs),
      sessions: %{total: safe_count_sessions()},
      pack: pack_status(),
      worktrees: %{total: length(list_worktrees())}
    }
  end

  defp agents_summary(jobs) do
    agents = list_agents(jobs)
    active = Enum.count(agents, &(&1.active_runs > 0))
    %{total: length(agents), with_active_runs: active}
  end

  # ── Jobs ──────────────────────────────────────────────────────────────

  @doc """
  Lists all known jobs (runs) with full UI-friendly details.

  `session_id` filters to a specific session. `nil` returns everything.
  """
  @spec list_jobs(String.t() | nil) :: [job()]
  def list_jobs(session_id \\ nil) do
    session_id
    |> Run.Manager.list_runs_with_details()
    |> Enum.map(&decorate_job/1)
  end

  @doc """
  Fetches a single job by its run_id. Returns `{:error, :not_found}` if
  the run process is gone (which is normal once a run is GC'd).
  """
  @spec get_job(String.t()) :: {:ok, job()} | {:error, :not_found}
  def get_job(run_id) when is_binary(run_id) do
    case Run.Manager.get_run(run_id) do
      {:ok, state} ->
        job =
          decorate_job(%{
            run_id: state.run_id,
            session_id: state.session_id,
            agent_name: state.agent_name,
            status: state.status,
            started_at: state.started_at,
            completed_at: state.completed_at,
            error: state.error,
            metadata: state.metadata || %{}
          })

        {:ok, job}

      {:error, :not_found} = err ->
        err
    end
  end

  @doc """
  Returns the most recent events recorded for a run, oldest first.

  This is only the events held in the per-run `Run.State` GenServer
  (a bounded buffer). For full history use the EventStore or a follow-up
  query — out of scope for v1 of the admin UI.
  """
  @spec list_job_events(String.t(), non_neg_integer()) :: [map()]
  def list_job_events(run_id, limit \\ 100) when is_binary(run_id) and is_integer(limit) do
    case Run.Manager.get_run(run_id) do
      {:ok, %{events: events}} when is_list(events) ->
        events |> Enum.reverse() |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp decorate_job(%{} = run) do
    duration =
      case {run[:started_at], run[:completed_at]} do
        {%DateTime{} = s, %DateTime{} = c} -> DateTime.diff(c, s, :millisecond)
        {%DateTime{} = s, nil} -> DateTime.diff(DateTime.utc_now(), s, :millisecond)
        _ -> nil
      end

    %{
      run_id: run[:run_id],
      session_id: run[:session_id],
      agent_name: run[:agent_name],
      status: run[:status] || :unknown,
      started_at: run[:started_at],
      completed_at: run[:completed_at],
      duration_ms: duration,
      error: run[:error],
      metadata: run[:metadata] || %{}
    }
  end

  # ── Agents ────────────────────────────────────────────────────────────

  @doc """
  Lists all agents in the catalogue with their live run counts.
  """
  @spec list_agents() :: [agent()]
  def list_agents, do: list_agents(list_jobs())

  @spec list_agents([job()]) :: [agent()]
  def list_agents(jobs) when is_list(jobs) do
    active_by_agent =
      jobs
      |> Enum.filter(&active_status?/1)
      |> Enum.frequencies_by(& &1.agent_name)

    AgentCatalogue.list_agents()
    |> Enum.map(fn info ->
      name = to_string(info.name)

      %{
        name: name,
        display_name: info.display_name,
        description: info.description,
        module: Map.get(info, :module),
        active_runs: Map.get(active_by_agent, name, 0)
      }
    end)
    |> Enum.sort_by(& &1.display_name)
  rescue
    e ->
      Logger.warning("Admin.Data.list_agents failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Returns the default agent name as configured by `AgentManager`.
  """
  @spec default_agent_name() :: String.t() | nil
  def default_agent_name do
    AgentManager.get_current_agent_name("admin-ui")
  rescue
    _ -> nil
  end

  defp active_status?(%{status: status}) when status in [:starting, :running, :paused, :pending],
    do: true

  defp active_status?(_), do: false

  # ── Sessions ──────────────────────────────────────────────────────────

  @doc """
  Lists chat sessions with metadata, newest first. Empty list on any
  error (e.g. missing migration during startup).
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    case Sessions.list_sessions_with_metadata() do
      {:ok, sessions} -> sessions
      _ -> []
    end
  rescue
    _ -> []
  end

  defp safe_count_sessions do
    Sessions.count_sessions()
  rescue
    _ -> 0
  end

  # ── Pack semaphore ────────────────────────────────────────────────────

  @doc """
  Snapshot of the pack-parallelism slot semaphore.
  """
  @spec pack_status() :: pack_status()
  def pack_status do
    PackParallelism.status()
  rescue
    _ -> %{limit: 0, active: 0, waiters: 0, available: 0}
  catch
    :exit, _ -> %{limit: 0, active: 0, waiters: 0, available: 0}
  end

  # ── Worktrees ─────────────────────────────────────────────────────────

  @doc """
  Lists git worktrees by parsing `git worktree list --porcelain`.

  Read-only. The admin UI does not create or remove worktrees — that
  is the terrier sub-agent's job (see `CodePuppyControl.Agents.Pack.Terrier`).
  """
  @spec list_worktrees(Path.t() | nil) :: [worktree()]
  def list_worktrees(cwd \\ nil) do
    case run_git_worktree(cwd) do
      {:ok, output} -> parse_worktree_porcelain(output)
      {:error, _} -> []
    end
  end

  defp run_git_worktree(cwd) do
    cwd = cwd || File.cwd!()

    case System.cmd("git", ["worktree", "list", "--porcelain"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:git_failed, code, output}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc false
  # Public for test only.
  @spec parse_worktree_porcelain(String.t()) :: [worktree()]
  def parse_worktree_porcelain(output) when is_binary(output) do
    output
    |> String.split(~r/\R\R/, trim: true)
    |> Enum.map(&parse_worktree_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_worktree_block(block) do
    lines = String.split(block, ~r/\R/, trim: true)

    base = %{
      path: nil,
      branch: nil,
      head: nil,
      bare: false,
      detached: false,
      locked: false
    }

    parsed =
      Enum.reduce(lines, base, fn line, acc ->
        case String.split(line, " ", parts: 2) do
          ["worktree", path] -> %{acc | path: path}
          ["HEAD", sha] -> %{acc | head: sha}
          ["branch", ref] -> %{acc | branch: short_branch(ref)}
          ["bare"] -> %{acc | bare: true}
          ["detached"] -> %{acc | detached: true}
          ["locked" | _] -> %{acc | locked: true}
          _ -> acc
        end
      end)

    if parsed.path, do: parsed, else: nil
  end

  defp short_branch("refs/heads/" <> name), do: name
  defp short_branch(other), do: other

  # ── Mutations (admin-safe) ─────────────────────────────────────────

  @doc """
  Updates the pack parallelism limit.
  """
  @spec set_pack_limit(non_neg_integer()) :: :ok | {:error, term()}
  def set_pack_limit(new_limit) do
    PackParallelism.set_limit(new_limit)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Deletes a chat session by name.
  """
  @spec delete_session(String.t()) :: :ok | {:error, term()}
  def delete_session(name) do
    Sessions.delete_session(name)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Scheduler ───────────────────────────────────────────────────────

  @doc """
  Lists all scheduled tasks.
  """
  @spec list_scheduled_tasks() :: [map()]
  def list_scheduled_tasks do
    Scheduler.list_tasks()
  rescue
    _ -> []
  end

  @doc """
  Gets scheduler statistics.
  """
  @spec get_scheduler_stats() :: map()
  def get_scheduler_stats do
    Scheduler.statistics()
  rescue
    _ -> %{total: 0, enabled: 0, disabled: 0, with_schedule: 0, one_shot: 0, last_24h_runs: 0}
  end

  @doc """
  Toggles a scheduled task's enabled state.
  """
  @spec toggle_task(integer()) :: {:ok, map()} | {:error, term()}
  def toggle_task(task_id) do
    case Scheduler.get_task(task_id) do
      {:ok, task} -> Scheduler.toggle_task(task)
      {:error, :not_found} -> {:error, :not_found}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Triggers immediate execution of a task.
  """
  @spec run_task_now(integer()) :: {:ok, map()} | {:error, term()}
  def run_task_now(task_id) do
    case Scheduler.run_task_now(task_id) do
      {:ok, job} -> {:ok, %{job_id: job.id}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
