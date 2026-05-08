defmodule CodePuppyControlWeb.CommandsController do
  @moduledoc """
  REST API controller for slash command discovery and autocomplete.

  Replaces `code_puppy/api/routers/commands.py` from the Python FastAPI server.

  ## Endpoints

  - `GET /api/commands` — List all available slash commands
  - `GET /api/commands/:name` — Get info about a specific command
  - `POST /api/commands/execute` — Execute a slash command (stub)
  - `POST /api/commands/autocomplete` — Get autocomplete suggestions
  """

  use CodePuppyControlWeb, :controller

  alias CodePuppyControl.CommandRegistry

  @doc """
  GET /api/commands

  Lists all available slash commands.

  Returns a sorted list of command info objects including name,
  description, usage, aliases, category, and detailed help.
  """
  def index(conn, _params) do
    commands = CommandRegistry.list_commands()
    json(conn, commands)
  end

  @doc """
  GET /api/commands/:name

  Gets detailed info about a specific command by name or alias.
  """
  def show(conn, %{"name" => name}) do
    case CommandRegistry.get_command(name) do
      {:ok, command} ->
        json(conn, command)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Command '/#{name}' not found"})
    end
  end

  @doc """
  POST /api/commands/execute

  Executes a slash command.

  Auth: Protected (Wave 5 will add auth plug; currently open for loopback-only deployment).

  Request body:
      { "command": "/set model=gpt-4o" }

  Currently returns 501 Not Implemented — subprocess command execution
  has not been ported to Elixir yet.
  """
  def execute(conn, _params) do
    # TODO(code-puppy-fuh): Implement command execution via Task.Supervisor + Port
    # The Python version runs commands in a subprocess with timeout.
    conn
    |> put_status(:not_implemented)
    |> json(%{
      error: "Command execution is not yet implemented in the Elixir server",
      suggestion: "Use the Python FastAPI server for command execution"
    })
  end

  @doc """
  POST /api/commands/autocomplete

  Gets autocomplete suggestions for a partial command.

  Auth: Protected (Wave 5 will add auth plug; currently open for loopback-only deployment).

  Request body:
      { "partial": "/se" }
  """
  def autocomplete(conn, %{"partial" => partial}) do
    suggestions = CommandRegistry.autocomplete(partial)
    json(conn, %{suggestions: suggestions})
  end

  def autocomplete(conn, _params) do
    json(conn, %{suggestions: []})
  end
end
