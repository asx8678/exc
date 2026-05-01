defmodule CodePuppyControlWeb.Admin.DashboardLive do
  @moduledoc """
  Admin dashboard — high-level system snapshot.

  ## Data flow

    * `mount/3` — load the initial snapshot from `Admin.Data.dashboard_summary/0`,
      subscribe to the global event firehose so we re-pull on activity,
      and start a 5-second tick for stale-pull (in case PubSub is briefly
      unavailable or events are silenced).
    * `handle_info({:event, _}, _)` — coalesce updates: just re-pull the
      summary. The summary is cheap; debouncing happens in the LiveView's
      natural rate of `render/1` calls.
    * `handle_info(:tick, _)` — periodic refresh (5s).

  ## Discipline

  Calls **only** `CodePuppyControlWeb.Admin.Data` — no direct reads from
  `Run.*`, `Tools.*`, `EventBus`, etc.
  """

  use CodePuppyControlWeb, :live_view

  alias CodePuppyControlWeb.Admin.Data

  @tick_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Data.subscribe_global_events()
      Process.send_after(self(), :tick, @tick_ms)
    end

    summary = Data.dashboard_summary()

    socket =
      socket
      |> assign(:active_nav, :dashboard)
      |> assign(:page_title, "Dashboard")
      |> assign(:status_line, status_line(summary))
      |> assign(:summary, summary)

    {:ok, socket}
  end

  @impl true
  def handle_info({:event, _ev}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Data.unsubscribe_global_events()
    :ok
  end

  defp refresh(socket) do
    summary = Data.dashboard_summary()

    socket
    |> assign(:summary, summary)
    |> assign(:status_line, status_line(summary))
  end

  defp status_line(%{pack: pack, jobs: jobs}) do
    active = Map.get(jobs.by_status, :running, 0) + Map.get(jobs.by_status, :starting, 0)
    "pack #{pack.active}/#{pack.limit} · active runs #{active}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="stat-grid">
      <.stat_card
        label="Active jobs"
        value={
          Map.get(@summary.jobs.by_status, :running, 0) +
            Map.get(@summary.jobs.by_status, :starting, 0)
        }
        sub={"of #{@summary.jobs.total} total"}
      />
      <.stat_card
        label="Pack slots"
        value={"#{@summary.pack.active}/#{@summary.pack.limit}"}
        sub={"#{@summary.pack.waiters} waiting"}
      />
      <.stat_card
        label="Agents"
        value={@summary.agents.total}
        sub={"#{@summary.agents.with_active_runs} with active runs"}
      />
      <.stat_card
        label="Worktrees"
        value={@summary.worktrees.total}
      />
      <.stat_card
        label="Sessions"
        value={@summary.sessions.total}
        sub="persisted in SQLite"
      />
    </section>

    <h2>Recent jobs</h2>
    <%= if @summary.jobs.recent == [] do %>
      <.empty_state message="No runs yet. Start one via the CLI or REPL." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Run ID</th>
            <th>Agent</th>
            <th>Status</th>
            <th>Started</th>
            <th>Duration</th>
          </tr>
        </thead>
        <tbody id="recent-jobs" phx-update="replace">
          <tr :for={job <- @summary.jobs.recent} id={"job-#{job.run_id}"}>
            <td class="mono">
              <.link navigate={~p"/admin/jobs/#{job.run_id}"}>
                {truncate(job.run_id, 28)}
              </.link>
            </td>
            <td>{job.agent_name || "—"}</td>
            <td><.status_pill status={job.status} /></td>
            <td class="mono">{format_dt(job.started_at)}</td>
            <td>{format_duration(job.duration_ms)}</td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end
end
