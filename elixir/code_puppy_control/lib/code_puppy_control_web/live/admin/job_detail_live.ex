defmodule CodePuppyControlWeb.Admin.JobDetailLive do
  @moduledoc """
  Admin job detail view — shows a single run's metadata and a live
  stream of its events.

  ## Discipline

    * Reads through `Admin.Data.get_job/1` and `Admin.Data.list_job_events/2`.
    * Subscribes to the run-specific PubSub topic so per-run events
      arrive in `handle_info/2` with no global firehose noise.
    * Uses an LV `stream/3` for events so we don't accumulate a giant
      assigns blob — each new event is inserted at the head and the
      stream itself caps growth via `:limit`.
  """

  use CodePuppyControlWeb, :live_view

  alias CodePuppyControlWeb.Admin.Data

  @event_stream_limit 200

  @impl true
  def mount(%{"id" => run_id}, _session, socket) do
    if connected?(socket), do: Data.subscribe_run(run_id)

    case Data.get_job(run_id) do
      {:ok, job} ->
        events = Data.list_job_events(run_id, @event_stream_limit)

        socket =
          socket
          |> assign(:active_nav, :jobs)
          |> assign(:page_title, "Job #{short(job.run_id)}")
          |> assign(:crumbs, ~s(<a href="/admin/jobs">Jobs</a> / #{job.run_id}))
          |> assign(:job, job)
          |> assign(:run_id, run_id)
          |> assign(:status_line, status_line(job))
          |> stream(:events, prepare_events(events), limit: @event_stream_limit)

        {:ok, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "Run #{run_id} not found (it may have been GC'd).")
          |> redirect(to: ~p"/admin/jobs")

        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:event, event}, socket) do
    job =
      case Data.get_job(socket.assigns.run_id) do
        {:ok, j} -> j
        _ -> socket.assigns.job
      end

    socket =
      socket
      |> assign(:job, job)
      |> assign(:status_line, status_line(job))
      |> stream_insert(:events, prepare_event(event), at: 0)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if id = socket.assigns[:run_id], do: Data.unsubscribe_run(id)
    :ok
  end

  defp short(<<head::binary-size(20), _::binary>>), do: head <> "…"
  defp short(other), do: other

  defp status_line(%{status: status, agent_name: agent}),
    do: "#{agent || "—"} · #{status}"

  defp prepare_events(events) when is_list(events),
    do: Enum.with_index(events) |> Enum.map(fn {ev, i} -> prepare_event(ev, i) end)

  defp prepare_event(event, i \\ nil) do
    type = event[:type] || event["type"] || "?"
    ts = event[:timestamp] || event["timestamp"]

    id =
      case i do
        nil ->
          # Stable per-event id from monotonic id+type fallback to a generated ref
          "ev-#{System.unique_integer([:positive, :monotonic])}-#{type}"

        idx ->
          "ev-init-#{idx}"
      end

    %{
      id: id,
      type: type,
      ts: ts,
      summary: summarize(event)
    }
  end

  defp summarize(%{} = ev) do
    cond do
      content = ev[:content] || ev["content"] -> truncate_summary(content)
      err = ev[:error] || ev["error"] -> "ERROR: " <> truncate_summary(err)
      msg = ev[:message] || ev["message"] -> truncate_summary(msg)
      tool = ev[:tool_name] || ev["tool_name"] -> "tool: #{tool}"
      status = ev[:status] || ev["status"] -> "status: #{status}"
      true -> ev |> Map.drop([:type, "type", :timestamp, "timestamp"]) |> inspect(limit: 5)
    end
  end

  defp truncate_summary(s) when is_binary(s) do
    if String.length(s) > 200, do: String.slice(s, 0, 199) <> "…", else: s
  end

  defp truncate_summary(other), do: inspect(other, limit: 5, printable_limit: 200)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="stat-grid">
      <.stat_card label="Status" value={Atom.to_string(@job.status)} />
      <.stat_card label="Agent" value={@job.agent_name || "—"} />
      <.stat_card label="Session" value={truncate(@job.session_id || "—", 24)} />
      <.stat_card label="Duration" value={format_duration(@job.duration_ms)} />
    </section>

    <h2>Metadata</h2>
    <pre>{inspect(@job.metadata, pretty: true, limit: 50)}</pre>

    <%= if @job.error do %>
      <h2>Error</h2>
      <pre>{inspect(@job.error, pretty: true, limit: 50)}</pre>
    <% end %>

    <h2>Live event stream</h2>
    <div id="event-stream" phx-update="stream" style="max-height:60vh; overflow-y:auto; background:#161b22; border:1px solid #30363d; border-radius:6px;">
      <div :for={{dom_id, ev} <- @streams.events} id={dom_id} class="event-row">
        <span class="ts">{format_ts(ev.ts)}</span>
        <span class="type">{ev.type}</span>
        <span>{ev.summary}</span>
      </div>
    </div>
    """
  end

  defp format_ts(nil), do: "?"
  defp format_ts(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp format_ts(other), do: inspect(other)
end
