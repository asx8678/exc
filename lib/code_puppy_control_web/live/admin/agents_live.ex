defmodule CodePuppyControlWeb.Admin.AgentsLive do
  @moduledoc """
  Admin agent catalogue view.

  Shows every agent registered with `Tools.AgentCatalogue` along with
  its description, module, and live count of active runs.

  ## Discipline

  Read-only. The actual agent registration lifecycle is owned by
  `Tools.AgentCatalogue` and `Tools.AgentManager` — this LiveView does
  NOT register, unregister, or mutate agents.
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

    {:ok, refresh(assign(socket, :active_nav, :agents))}
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
    agents = Data.list_agents()
    default = Data.default_agent_name()

    socket
    |> assign(:page_title, "Agents")
    |> assign(:agents, agents)
    |> assign(:default_agent, default)
    |> assign(:status_line, "#{length(agents)} agents · default: #{default || "—"}")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @agents == [] do %>
      <.empty_state message="No agents discovered. Is the AgentCatalogue running?" />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Display</th>
            <th>Active runs</th>
            <th>Module</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={agent <- @agents} id={"agent-#{agent.name}"}>
            <td class="mono">
              {agent.name}
              <span :if={agent.name == @default_agent} class="muted"> · default</span>
            </td>
            <td>{agent.display_name}</td>
            <td>{agent.active_runs}</td>
            <td class="mono">{module_short(agent.module)}</td>
            <td>{truncate(agent.description, 120)}</td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp module_short(nil), do: "—"

  defp module_short(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp module_short(other), do: inspect(other)
end
