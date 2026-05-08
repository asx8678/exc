defmodule CodePuppyControlWeb.Admin.WorktreesLive do
  @moduledoc """
  Admin worktree view.

  Lists git worktrees discovered by `git worktree list --porcelain`.
  Read-only — terrier (the pack worktree-management sub-agent) is the
  authoritative writer. The admin UI does not create, lock, or remove
  worktrees in v1.
  """

  use CodePuppyControlWeb, :live_view

  alias CodePuppyControlWeb.Admin.Data

  @tick_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)
    {:ok, refresh(assign(socket, :active_nav, :worktrees))}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    worktrees = Data.list_worktrees()

    socket
    |> assign(:page_title, "Worktrees")
    |> assign(:worktrees, worktrees)
    |> assign(:status_line, "#{length(worktrees)} worktrees")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p class="muted" style="margin-bottom:1rem">
      Read-only view of <code>git worktree list</code> for the control-plane
      working directory. The terrier pack agent is the authoritative writer.
      <button phx-click="refresh" style="margin-left:1rem">Refresh</button>
    </p>

    <%= if @worktrees == [] do %>
      <.empty_state message="No worktrees discovered. Is this directory a git repository?" />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Path</th>
            <th>Branch</th>
            <th>HEAD</th>
            <th>Flags</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={wt <- @worktrees} id={"wt-#{Base.encode16(:crypto.hash(:sha, wt.path))}"}>
            <td class="mono">{wt.path}</td>
            <td class="mono">{wt.branch || (wt.detached && "(detached)") || "—"}</td>
            <td class="mono">{short_sha(wt.head)}</td>
            <td>{flags(wt)}</td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp short_sha(nil), do: "—"
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 8)

  defp flags(wt) do
    [
      wt.bare && "bare",
      wt.detached && "detached",
      wt.locked && "locked"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "—"
      list -> Enum.join(list, ", ")
    end
  end
end
