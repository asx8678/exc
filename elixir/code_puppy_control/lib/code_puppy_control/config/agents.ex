defmodule CodePuppyControl.Config.Agents do
  @moduledoc """
  Agent configuration accessors.

  Manages the default agent, agent directories, and related preferences.

  ## Config keys in `puppy.cfg`

  - `default_agent` — name of the default agent (default `"code-puppy"`)
  - `puppy_name` — display name for the puppy
  - `owner_name` — display name for the owner
  """

  alias CodePuppyControl.Config.{Loader, Paths}

  @default_agent_name "code-puppy"

  # ── Default agent ───────────────────────────────────────────────────────

  @doc """
  Return the default agent name. Falls back to `"code-puppy"`.
  """
  @spec default_agent() :: String.t()
  def default_agent do
    Loader.get_value("default_agent") || @default_agent_name
  end

  @doc """
  Set the default agent name.
  """
  @spec set_default_agent(String.t()) :: :ok
  def set_default_agent(agent_name) when is_binary(agent_name) do
    CodePuppyControl.Config.Writer.set_value("default_agent", agent_name)
  end

  # ── Personalization ─────────────────────────────────────────────────────

  @doc """
  Return the puppy's display name. Defaults to `"Puppy"`.
  """
  @spec puppy_name() :: String.t()
  def puppy_name do
    Loader.get_value("puppy_name") || "Puppy"
  end

  @doc """
  Return the owner's display name. Defaults to `"Master"`.
  """
  @spec owner_name() :: String.t()
  def owner_name do
    Loader.get_value("owner_name") || "Master"
  end

  # ── Agent directories ───────────────────────────────────────────────────

  @doc """
  Return the user-level agents directory. Ensures it exists.
  """
  @spec user_agents_dir() :: String.t()
  def user_agents_dir do
    dir = Paths.agents_dir()
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Return the project-local agents directory if `.code_puppy/agents/` exists
  in CWD, or `nil`.
  """
  @spec project_agents_dir() :: String.t() | nil
  def project_agents_dir do
    Paths.project_agents_dir()
  end

  @doc """
  Return all agent directories to search (project first, then user).
  """
  @spec agent_search_paths() :: [String.t()]
  def agent_search_paths do
    [project_agents_dir(), user_agents_dir()]
    |> Enum.filter(&(&1 != nil))
  end
end
