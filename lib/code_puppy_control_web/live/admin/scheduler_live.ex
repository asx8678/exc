defmodule CodePuppyControlWeb.Admin.SchedulerLive do
  @moduledoc """
  Admin scheduler view — manage scheduled tasks.

  ## Data flow

    * `mount/3` — load the initial snapshot from `Admin.Data.list_scheduled_tasks/0` and
      `Admin.Data.get_scheduler_stats/0`, subscribe to the global event firehose so we
      re-pull on activity, and start a 5-second tick for stale-pull.
    * `handle_event("toggle", _, _)` — toggles a task's enabled state via `Admin.Data.toggle_task/1`.
    * `handle_event("run_now", _, _)` — triggers immediate execution via `Admin.Data.run_task_now/1`.
    * `handle_info({:event, _}, _)` — re-pull tasks and stats on activity.
    * `handle_info(:tick, _)` — periodic refresh (5s).

  ## Discipline

  Calls **only** `CodePuppyControlWeb.Admin.Data` — no direct reads from
  `Scheduler.*`, `EventBus`, etc.
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

    {:ok, refresh(assign(socket, :active_nav, :scheduler))}
  end

  @impl true
  def handle_event("toggle", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        case Data.toggle_task(id) do
          {:ok, _task} ->
            {:noreply, refresh(put_flash(socket, :info, "Task toggled."))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle task: #{reason}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid task ID")}
    end
  end

  @impl true
  def handle_event("run_now", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        case Data.run_task_now(id) do
          {:ok, _job} ->
            {:noreply, refresh(put_flash(socket, :info, "Task execution triggered."))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to trigger task: #{reason}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid task ID")}
    end
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
    socket
    |> assign(:tasks, Data.list_scheduled_tasks())
    |> assign(:stats, Data.get_scheduler_stats())
    |> assign(:page_title, "Scheduler")
  end

  defp format_schedule(task) do
    case task.schedule_type do
      "cron" -> task.schedule
      "interval" -> "Every #{task.schedule_value}"
      "hourly" -> "Hourly"
      "daily" -> "Daily"
      "one_shot" -> "One-shot"
      _ -> task.schedule_type
    end
  end

  defp status_class("success"), do: "success"
  defp status_class("failed"), do: "error"
  defp status_class("running"), do: "info"
  defp status_class(_), do: "neutral"

  @impl true
  def render(assigns) do
    ~H"""
    <section class="stat-grid">
      <.stat_card label="Total Tasks" value={@stats.total} />
      <.stat_card label="Enabled" value={@stats.enabled} />
      <.stat_card label="Disabled" value={@stats.disabled} />
      <.stat_card label="Runs (24h)" value={@stats.last_24h_runs} />
    </section>

    <%= if @tasks == [] do %>
      <.empty_state message="No scheduled tasks configured." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Agent</th>
            <th>Schedule</th>
            <th>Enabled</th>
            <th>Last Run</th>
            <th>Status</th>
            <th>Runs</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={task <- @tasks} id={"task-#{task.id}"}>
            <td>{task.name}</td>
            <td>{task.agent_name}</td>
            <td class="mono">{format_schedule(task)}</td>
            <td>
              <span class={"status-pill #{if task.enabled, do: "success", else: "neutral"}"}>
                {if task.enabled, do: "Yes", else: "No"}
              </span>
            </td>
            <td class="mono">{format_dt(task.last_run_at)}</td>
            <td>
              <span :if={task.last_status} class={"status-pill #{status_class(task.last_status)}"}>
                {task.last_status}
              </span>
              <span :if={!task.last_status} class="status-pill neutral">—</span>
            </td>
            <td>{task.run_count}</td>
            <td style="white-space: nowrap;">
              <button 
                phx-click="toggle" 
                phx-value-id={task.id} 
                class="btn-primary btn-sm"
                style="margin-right: 0.5rem;">
                {if task.enabled, do: "Disable", else: "Enable"}
              </button>
              <button 
                phx-click="run_now" 
                phx-value-id={task.id} 
                class="btn-primary btn-sm">
                Run Now
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end
end
