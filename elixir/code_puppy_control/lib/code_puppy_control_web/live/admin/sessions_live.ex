defmodule CodePuppyControlWeb.Admin.SessionsLive do
  @moduledoc """
  Admin sessions view.

  Lists all persisted chat sessions with metadata and supports deletion.

  ## Discipline

  Read-only for listing; deletion is wrapped in `Admin.Data.delete_session/1`
  which is a safe admin mutation.
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

    {:ok, refresh(assign(socket, :active_nav, :sessions))}
  end

  @impl true
  def handle_event("delete", %{"name" => name}, socket) do
    case Data.delete_session(name) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Session \"#{name}\" deleted.")
          |> refresh()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session: #{reason}")}
    end
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
    sessions = Data.list_sessions()

    socket
    |> assign(:page_title, "Sessions")
    |> assign(:sessions, sessions)
    |> assign(:status_line, "#{length(sessions)} sessions persisted in SQLite")
  end

  defp format_session_timestamp(nil), do: "—"

  defp format_session_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_session_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> format_session_timestamp(dt)
      _ -> timestamp
    end
  end

  defp format_session_timestamp(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @sessions == [] do %>
      <.empty_state message="No sessions saved yet." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Messages</th>
            <th>Tokens</th>
            <th>Auto-saved</th>
            <th>Terminal</th>
            <th>Timestamp</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={session <- @sessions} id={"session-#{session.name}"}>
            <td class="mono">{session.name}</td>
            <td>{session.message_count}</td>
            <td>{session.total_tokens}</td>
            <td>
              <span :if={session.auto_saved} class="status-pill success">Yes</span>
              <span :if={!session.auto_saved} class="status-pill neutral">No</span>
            </td>
            <td>
              <span :if={session.has_terminal} class="status-pill info">Active</span>
              <span :if={!session.has_terminal} class="status-pill neutral">—</span>
            </td>
            <td class="mono">{format_session_timestamp(session.timestamp)}</td>
            <td>
              <button
                phx-click="delete"
                phx-value-name={session.name}
                class="btn-danger btn-sm"
                data-confirm="Are you sure you want to delete this session?">
                Delete
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end
end
