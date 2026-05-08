defmodule CodePuppyControlWeb.AgentsController do
  @moduledoc """
  REST API controller for agent management.

  Replaces `code_puppy/api/routers/agents.py` from the Python FastAPI server.

  ## Endpoints

  - `GET /api/agents` — List all available agents with their metadata
  """

  use CodePuppyControlWeb, :controller

  alias CodePuppyControl.Tools.AgentCatalogue

  @doc """
  GET /api/agents

  Lists all available agents registered in the system,
  including their name, display name, and description.
  """
  def index(conn, _params) do
    agents =
      AgentCatalogue.list_agents()
      |> Enum.map(fn agent_info ->
        %{
          name: agent_info.name,
          display_name: agent_info.display_name,
          description: agent_info.description
        }
      end)

    json(conn, agents)
  end
end
