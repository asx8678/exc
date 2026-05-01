defmodule CodePuppyControlWeb.Admin.PackLive do
  @moduledoc """
  Admin pack-parallelism view.

  Shows the live state of `Plugins.PackParallelism`: limit, active,
  waiters, available. Refreshes on every global event (which is when
  the semaphore meaningfully changes) plus a 2-second tick so the
  visible counts feel snappy.

  ## Discipline

  Read-only. Limit changes go through `/pack-parallel` slash commands
  or the underlying `PackParallelism.set_limit/1` API — the admin UI
  in v1 does not expose mutation. If/when we add it, the mutation
  surface MUST be a separate, audit-logged action; not a free-form
  number input.
  """

  use CodePuppyControlWeb, :live_view

  alias CodePuppyControlWeb.Admin.Data

  @tick_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Data.subscribe_global_events()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, refresh(assign(socket, :active_nav, :pack))}
  end

  @impl true
  def handle_info({:event, _ev}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Data.unsubscribe_global_events()
    :ok
  end

  defp refresh(socket) do
    pack = Data.pack_status()
    jobs = Data.list_jobs() |> Enum.filter(&(&1.status in [:starting, :running, :paused]))

    socket
    |> assign(:page_title, "Pack")
    |> assign(:pack, pack)
    |> assign(:active_jobs, jobs)
    |> assign(:status_line, "#{pack.active}/#{pack.limit} slots · #{pack.waiters} waiting")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="stat-grid">
      <.stat_card label="Limit" value={@pack.limit} />
      <.stat_card label="Active" value={@pack.active} sub="slots in use" />
      <.stat_card label="Available" value={@pack.available} />
      <.stat_card
        label="Waiters"
        value={@pack.waiters}
        sub={(@pack.waiters > 0 && "queued for a slot") || nil}
      />
    </section>

    <h2>Active runs holding slots</h2>
    <%= if @active_jobs == [] do %>
      <.empty_state message="No active runs are holding pack slots right now." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Run ID</th>
            <th>Agent</th>
            <th>Status</th>
            <th>Started</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={job <- @active_jobs} id={"pack-job-#{job.run_id}"}>
            <td class="mono">
              <.link navigate={~p"/admin/jobs/#{job.run_id}"}>
                {truncate(job.run_id, 28)}
              </.link>
            </td>
            <td>{job.agent_name || "—"}</td>
            <td><.status_pill status={job.status} /></td>
            <td class="mono">{format_dt(job.started_at)}</td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end
end
