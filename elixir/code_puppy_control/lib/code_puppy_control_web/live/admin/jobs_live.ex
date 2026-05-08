defmodule CodePuppyControlWeb.Admin.JobsLive do
  @moduledoc """
  Admin job (run) list view.

  ## Discipline

    * Reads jobs through `Admin.Data.list_jobs/0` only.
    * Subscribes to the global event firehose so newly-created or
      status-changed jobs surface without a page refresh.
    * Uses an LV `stream/3` so we don't shovel the entire job list
      across the wire on every event.
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

    socket =
      socket
      |> assign(:active_nav, :jobs)
      |> assign(:page_title, "Jobs")
      |> assign(:filter_status, :all)
      |> stream_jobs(Data.list_jobs())

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    parsed = parse_status_filter(status)

    socket =
      socket
      |> assign(:filter_status, parsed)
      |> stream_jobs(filter_jobs(Data.list_jobs(), parsed), reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:event, %{type: type} = ev}, socket)
      when type in ["status", "completed", "failed", "cancelled", "started"] do
    case event_run_id(ev) do
      nil ->
        {:noreply, socket}

      run_id ->
        case Data.get_job(run_id) do
          {:ok, job} ->
            if matches_filter?(job, socket.assigns.filter_status) do
              {:noreply, stream_insert(socket, :jobs, job, at: 0)}
            else
              {:noreply, stream_delete_by_dom_id(socket, :jobs, "job-#{run_id}")}
            end

          {:error, :not_found} ->
            {:noreply, stream_delete_by_dom_id(socket, :jobs, "job-#{run_id}")}
        end
    end
  end

  @impl true
  def handle_info({:event, _ev}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    jobs = Data.list_jobs() |> filter_jobs(socket.assigns.filter_status)
    {:noreply, stream_jobs(socket, jobs, reset: true)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Data.unsubscribe_global_events()
    :ok
  end

  # ── Stream helpers ────────────────────────────────────────────────────

  defp stream_jobs(socket, jobs, opts \\ []) do
    sorted =
      jobs
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.map(&Map.put(&1, :id, "job-#{&1.run_id}"))

    socket
    |> assign(:status_line, "#{length(sorted)} jobs")
    |> stream(:jobs, sorted, opts)
  end

  defp filter_jobs(jobs, :all), do: jobs
  defp filter_jobs(jobs, status), do: Enum.filter(jobs, &(&1.status == status))

  defp matches_filter?(_job, :all), do: true
  defp matches_filter?(job, status), do: job.status == status

  # Whitelist of valid filter atoms — never call String.to_atom on user input.
  @valid_filter_atoms ~w(starting running completed failed cancelled paused pending)a
  @valid_filter_strings Enum.map(@valid_filter_atoms, &Atom.to_string/1)

  defp parse_status_filter("all"), do: :all

  defp parse_status_filter(s) when is_binary(s) do
    if s in @valid_filter_strings do
      String.to_existing_atom(s)
    else
      :all
    end
  end

  defp parse_status_filter(_), do: :all

  defp event_run_id(%{run_id: id}) when is_binary(id), do: id
  defp event_run_id(%{"run_id" => id}) when is_binary(id), do: id
  defp event_run_id(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <form phx-change="filter" style="margin-bottom:1rem">
      <label>
        Status:
        <select name="status">
          <option value="all" selected={@filter_status == :all}>All</option>
          <option
            :for={s <- ~w(starting running completed failed cancelled paused)a}
            value={s}
            selected={@filter_status == s}
          >{s}</option>
        </select>
      </label>
    </form>

    <table class="admin-table">
      <thead>
        <tr>
          <th>Run ID</th>
          <th>Session</th>
          <th>Agent</th>
          <th>Status</th>
          <th>Started</th>
          <th>Duration</th>
        </tr>
      </thead>
      <tbody id="jobs" phx-update="stream">
        <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
          <td class="mono">
            <.link navigate={~p"/admin/jobs/#{job.run_id}"}>
              {truncate(job.run_id, 28)}
            </.link>
          </td>
          <td class="mono">{truncate(job.session_id || "—", 18)}</td>
          <td>{job.agent_name || "—"}</td>
          <td><.status_pill status={job.status} /></td>
          <td class="mono">{format_dt(job.started_at)}</td>
          <td>{format_duration(job.duration_ms)}</td>
        </tr>
      </tbody>
    </table>

    <div :if={Enum.empty?(@streams.jobs.inserts)} id="jobs-empty">
      <.empty_state message="No jobs match the current filter." />
    </div>
    """
  end
end
