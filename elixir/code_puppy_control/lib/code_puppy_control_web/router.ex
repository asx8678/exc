defmodule CodePuppyControlWeb.Router do
  @moduledoc """
  Router for CodePuppy Control Plane API.

  ## API Endpoints

  ### Run Management
  - `POST /api/runs` - Create a new run
  - `GET /api/runs/:id` - Get run status
  - `DELETE /api/runs/:id` - Stop and cleanup a run

  ### Tool Execution
  - `POST /api/runs/:id/execute` - Execute a tool via Python worker
  - `GET /api/runs/:id/history` - Get run request/response history

  ### Sessions (Wave 2)
  - `GET /api/sessions` - List sessions with pagination
  - `GET /api/sessions/:id` - Get session metadata
  - `GET /api/sessions/:id/messages` - Get session messages
  - `DELETE /api/sessions/:id` - Delete a session

  ### Config (Wave 2)
  - `GET /api/config` - List all config keys/values
  - `GET /api/config/keys` - List valid config keys
  - `GET /api/config/:key` - Get a config value
  - `PUT /api/config/:key` - Set a config value
  - `DELETE /api/config/:key` - Reset a config value

  ### Agents (Wave 2)
  - `GET /api/agents` - List all available agents

  ### Commands (Wave 2)
  - `GET /api/commands` - List all slash commands
  - `GET /api/commands/:name` - Get command info
  - `POST /api/commands/execute` - Execute a command
  - `POST /api/commands/autocomplete` - Get autocomplete suggestions

  ### MCP Server Management
  - `GET /api/mcp` - List MCP servers
  - `POST /api/mcp` - Register MCP server
  - `GET /api/mcp/:id` - Get server status
  - `DELETE /api/mcp/:id` - Unregister server
  - `POST /api/mcp/:id/call` - Call a tool
  - `POST /api/mcp/:id/restart` - Restart server
  - `GET /api/mcp/health` - MCP health check

  ### Health & Metrics
  - `GET /health` - Health check
  - `GET /metrics` - Prometheus metrics (if configured)
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authenticated API pipeline — mutating operations require auth
  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug CodePuppyControlWeb.Plugs.Auth
  end

  # Admin LiveView UI pipeline (code_puppy-yge.3).
  # Localhost-only by default — see CodePuppyControlWeb.Plugs.AdminAuth.
  # The admin UI is an OPTIONAL surface; removing this pipeline + the
  # `live_session :admin` block below leaves the API endpoints intact.
  pipeline :admin_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CodePuppyControlWeb.Admin.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CodePuppyControlWeb.Plugs.AdminAuth
  end

  # Public endpoints — no auth required
  scope "/", CodePuppyControlWeb do
    pipe_through :api

    get "/", InfoController, :index
    get "/health", HealthController, :index
    get "/health/runtime", HealthController, :runtime
  end

  # Authenticated API endpoints — mutating operations
  scope "/api", CodePuppyControlWeb do
    pipe_through :authenticated_api

    # Run management
    resources "/runs", RunController, only: [:create, :show, :delete]
    post "/runs/:id/execute", RunController, :execute
    get "/runs/:id/history", RunController, :history

    # Session management (Wave 2)
    get "/sessions", SessionsController, :index
    get "/sessions/:id", SessionsController, :show
    get "/sessions/:id/messages", SessionsController, :messages
    delete "/sessions/:id", SessionsController, :delete

    # Configuration management (Wave 2)
    get "/config", ConfigController, :index
    get "/config/keys", ConfigController, :keys
    get "/config/:key", ConfigController, :show
    put "/config/:key", ConfigController, :update
    delete "/config/:key", ConfigController, :delete

    # Agent management (Wave 2)
    get "/agents", AgentsController, :index

    # Command management (Wave 2)
    get "/commands", CommandsController, :index
    get "/commands/:name", CommandsController, :show
    post "/commands/execute", CommandsController, :execute
    post "/commands/autocomplete", CommandsController, :autocomplete

    # MCP Server endpoints
    resources "/mcp", MCPController, only: [:index, :create, :show, :delete]
    post "/mcp/:id/call", MCPController, :call_tool
    post "/mcp/:id/restart", MCPController, :restart
    get "/mcp/health", MCPController, :health
  end

  # Admin LiveView UI (code_puppy-yge.3) — observe-only pack orchestration UI.
  scope "/admin", CodePuppyControlWeb.Admin do
    pipe_through :admin_browser

    live_session :admin,
      on_mount: [{CodePuppyControlWeb.Plugs.AdminAuth, :default}],
      root_layout: {CodePuppyControlWeb.Admin.Layouts, :root} do
      live "/", DashboardLive, :index
      live "/agents", AgentsLive, :index
      live "/jobs", JobsLive, :index
      live "/jobs/:id", JobDetailLive, :show
      live "/worktrees", WorktreesLive, :index
      live "/pack", PackLive, :index
    end
  end

  # LiveDashboard is available in development for monitoring
  # To enable, add :phoenix_live_dashboard to deps and uncomment below:
  # if Mix.env() == :dev do
  # import Phoenix.LiveDashboard.Router
  #
  # scope "/dev" do
  # pipe_through [:fetch_session, :protect_from_forgery]
  #
  # live_dashboard "/dashboard",
  # metrics: CodePuppyControlWeb.Telemetry,
  # ecto_repos: [CodePuppyControl.Repo]
  # end
  # end
end
