defmodule CodePuppyControlWeb.Admin.PackLive do
  @moduledoc """
  Admin pack-parallelism + cluster orchestration view.

  Shows the live state of `Plugins.PackParallelism` (limit, active,
  waiters, available) AND the distributed cluster topology (connected
  workers, capabilities, dispatch history, cluster health).

  Refreshes on every global event plus a 2-second tick.

  ## Discipline

  Read-only. Limit changes go through `/pack-parallel` slash commands
  or the underlying `PackParallelism.set_limit/1` API — the admin UI
  in v1 does not expose mutation.

  (Extended in code_puppy-df1.2 for cluster orchestration.)
  """

  use CodePuppyControlWeb, :live_view

  alias CodePuppyControlWeb.Admin.Data
  alias CodePuppyControl.Telemetry.ClusterDashboard

  @tick_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Data.subscribe_global_events()
      ClusterDashboard.subscribe()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, refresh(assign(socket, :active_nav, :pack))}
  end

  @impl true
  def handle_info({:event, _ev}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_info({:dashboard_update, _update}, socket), do: {:noreply, refresh(socket)}

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
    cluster = ClusterDashboard.snapshot()

    socket
    |> assign(:page_title, "Pack")
    |> assign(:pack, pack)
    |> assign(:active_jobs, jobs)
    |> assign(:status_line, "#{pack.active}/#{pack.limit} slots · #{pack.waiters} waiting")
    |> assign(:cluster, cluster)
    |> assign(:cluster_nodes, cluster.nodes)
    |> assign(:cluster_health, cluster.cluster_health)
    |> assign(:dispatch_history, Enum.take(cluster.dispatch_history, 20))
    |> assign(:cluster_totals, cluster.totals)
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

    <%!-- Cluster Orchestration Section (code_puppy-df1.2) --%>
    <section class="cluster-section" style="margin-top: 2rem;">
      <h2>Cluster Topology</h2>
      <section class="stat-grid">
        <.stat_card label="Health" value={@cluster_health} />
        <.stat_card label="Connected Nodes" value={@cluster.connected_nodes} />
        <.stat_card label="Total Dispatches" value={@cluster_totals.dispatches} />
        <.stat_card
          label="Success Rate"
          value={success_rate(@cluster_totals)}
          sub="successful dispatches"
        />
      </section>

      <%= if map_size(@cluster_nodes) > 0 do %>
        <h3>Worker Nodes</h3>
        <table class="admin-table">
          <thead>
            <tr>
              <th>Node</th>
              <th>Status</th>
              <th>Active Runs</th>
              <th>Completed</th>
              <th>Capabilities</th>
            </tr>
          </thead>
          <tbody>
            <%= for {node_name, info} <- @cluster_nodes do %>
              <tr id={"cluster-node-#{node_name}"}>
                <td class="mono"><%= inspect(node_name) %></td>
                <td><.status_pill status={info.status} /></td>
                <td><%= info.active_runs %></td>
                <td><%= info.total_completed %></td>
                <td class="mono">
                  <%= format_capabilities(info.capabilities) %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% else %>
        <.empty_state message="No worker nodes connected. Start a worker with --sname pup_worker_01." />
      <% end %>

      <%= if @dispatch_history != [] do %>
        <h3>Recent Dispatches</h3>
        <table class="admin-table">
          <thead>
            <tr>
              <th>Run ID</th>
              <th>Sub-Agent</th>
              <th>Target</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <%= for entry <- @dispatch_history do %>
              <tr id={"dispatch-#{entry.run_id}"}>
                <td class="mono"><%= truncate(entry.run_id, 20) %></td>
                <td><%= entry.sub_agent %></td>
                <td class="mono"><%= inspect(entry.target_node) %></td>
                <td><.status_pill status={entry.status} /></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp success_rate(%{dispatches: 0}), do: "—"
  defp success_rate(%{dispatches: total, successes: success}) do
    pct = Float.round(success / total * 100, 1)
    "#{pct}%"
  end

  defp format_capabilities(nil), do: "—"
  defp format_capabilities(caps) when is_map(caps) do
    caps
    |> Map.get(:sub_agent_names, [])
    |> Enum.join(", ")
  end
  defp format_capabilities(_), do: "—"
end
