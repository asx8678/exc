defmodule CodePuppyControl.Agent.Lifecycle do
  @moduledoc """
  Agent lifecycle: model resolution, MCP server loading, and prompt assembly.

  Ports Python's BaseAgent methods for agent construction and wiring:
  - `_load_model_with_fallback` — Model loading with friendly fallback
  - `load_puppy_rules` — Load AGENTS.md rules from config + project
  - `load_mcp_servers` / `reload_mcp_servers` — MCP server management
  - Model pack resolution for `{:pack, role}` model preference
  - System prompt assembly (base prompt + puppy rules + model hooks)

  ## Design decisions

  - **Pure functions where possible** — Model resolution and prompt
    assembly are pure. MCP server loading has side effects (I/O).
  - **Graceful degradation** — Model fallback, missing rules, and
    unavailable MCP servers all fail gracefully rather than crashing.
  - **Config-driven** — All behavior comes from `CodePuppyControl.Config`
    or the agent module's behaviour callbacks.

  ## Integration with Agent.Loop

  The loop calls `resolve_model/2` during initialization and
  `assemble_system_prompt/2` before each LLM call. MCP server loading
  happens at agent construction time (or reload).
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Model Resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the effective model name for an agent.

  Handles three cases:
  1. `model_override` — Explicit model from loop opts (highest priority)
  2. `{:pack, role}` — Model pack resolution (delegates to ModelPacks)
  3. Direct model name string from `agent_module.model_preference/0`

  Falls back to a hardcoded default if resolution fails.

  ## Examples

      iex> Lifecycle.resolve_model("claude-sonnet-4-20250514", nil)
      "claude-sonnet-4-20250514"

      iex> Lifecycle.resolve_model(nil, "gpt-4o")
      "gpt-4o"
  """
  @spec resolve_model(String.t() | nil, String.t() | nil) :: String.t()
  def resolve_model(model_override, agent_preference) do
    cond do
      is_binary(model_override) and model_override != "" ->
        model_override

      true ->
        case agent_preference do
          {:pack, role} ->
            resolve_pack_model(role)

          model_name when is_binary(model_name) and model_name != "" ->
            model_name

          _ ->
            Logger.warning("Lifecycle: no model preference, using default")
            default_model()
        end
    end
  end

  @doc """
  Load a model with friendly fallback on failure.

  Tries the requested model first. If unavailable, falls back to:
  1. The global model from config
  2. The first available model in config
  3. A hardcoded default

  This is the Elixir port of Python's `_load_model_with_fallback`.

  ## Parameters

    * `requested_model` — The model name to try first
    * `available_models` — List of available model names

  ## Returns

    * `{:ok, model_name}` — Successfully resolved model
    * `{:error, reason}` — No model could be loaded
  """
  @spec load_model_with_fallback(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def load_model_with_fallback(requested_model, available_models) do
    if requested_model in available_models do
      {:ok, requested_model}
    else
      Logger.warning(
        "Lifecycle: model '#{requested_model}' not found. Available: #{Enum.join(available_models, ", ")}"
      )

      # Try fallback candidates
      candidates = build_fallback_candidates(available_models)

      case Enum.find(candidates, &(&1 in available_models)) do
        nil ->
          {:error, "No valid model could be loaded. Update the model configuration."}

        fallback ->
          Logger.info("Lifecycle: using fallback model: #{fallback}")
          {:ok, fallback}
      end
    end
  end

  defp build_fallback_candidates(available_models) do
    global_model = global_model_name()
    candidates = if global_model, do: [global_model], else: []
    candidates ++ Enum.sort(available_models)
  end

  # ---------------------------------------------------------------------------
  # Puppy Rules
  # ---------------------------------------------------------------------------

  @doc """
  Load AGENTS.md rules from global config and project directories.

  Checks for AGENTS.md, AGENT.md, agents.md, agent.md in:
  1. Global config directory (~/.code_puppy/)
  2. Current working directory (project-specific)

  If both exist, they are combined with global rules first.

  This is the Elixir port of Python's `load_puppy_rules`.

  ## Examples

      iex> Lifecycle.load_puppy_rules()
      nil  # When no AGENTS.md files exist
  """
  @spec load_puppy_rules() :: String.t() | nil
  def load_puppy_rules do
    possible_names = ["AGENTS.md", "AGENT.md", "agents.md", "agent.md"]

    global_rules = find_rules_file(config_dir(), possible_names)
    project_rules = find_rules_file(File.cwd!(), possible_names)

    rules = [global_rules, project_rules] |> Enum.reject(&is_nil/1)

    if rules == [] do
      nil
    else
      Enum.join(rules, "\n\n")
    end
  end

  defp find_rules_file(dir, possible_names) do
    Enum.find_value(possible_names, fn name ->
      path = Path.join(dir, name)

      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    end)
  end

  defp config_dir do
    # Use PUP_ prefix per naming convention
    System.get_env("PUP_CONFIG_DIR") ||
      System.get_env("PUPPY_HOME") ||
      Path.join(System.user_home!(), ".code_puppy")
  end

  # ---------------------------------------------------------------------------
  # System Prompt Assembly
  # ---------------------------------------------------------------------------

  @doc """
  Assemble the full system prompt for an agent run.

  Combines:
  1. Base system prompt from `agent_module.system_prompt/1`
  2. Puppy rules (AGENTS.md content)
  3. Model-specific adaptations (future: prepare_prompt_for_model)

  ## Parameters

    * `agent_module` — Module implementing `Agent.Behaviour`
    * `context` — Context map passed to `system_prompt/1`

  ## Returns

    * `{:ok, prompt}` — Assembled system prompt

  ## Examples

      iex> defmodule TestAgent do
      ...>   use CodePuppyControl.Agent.Behaviour
      ...>   @impl true
      ...>   def name, do: :test
      ...>   @impl true
      ...>   def system_prompt(_), do: "You are a test agent."
      ...>   @impl true
      ...>   def allowed_tools, do: []
      ...>   @impl true
      ...>   def model_preference, do: "claude-sonnet-4-20250514"
      ...> end
      iex> {:ok, prompt} = Lifecycle.assemble_system_prompt(TestAgent, %{})
      iex> String.contains?(prompt, "You are a test agent.")
      true
  """
  @spec assemble_system_prompt(module(), map()) :: {:ok, String.t()}
  def assemble_system_prompt(agent_module, context) do
    base_prompt = agent_module.system_prompt(context)

    # Append puppy rules if available
    case load_puppy_rules() do
      nil ->
        {:ok, base_prompt}

      rules ->
        {:ok, base_prompt <> "\n\n" <> rules}
    end
  end

  # ---------------------------------------------------------------------------
  # MCP Server Loading
  # ---------------------------------------------------------------------------

  @doc """
  Load MCP servers for the current agent.

  Delegates to `CodePuppyControl.MCP.Manager` if available.
  Returns an empty list if MCP is disabled or unavailable.

  This is the Elixir port of Python's `load_mcp_servers`.
  """
  @spec load_mcp_servers(keyword()) :: [map()]
  def load_mcp_servers(_opts \\ []) do
    # Check if MCP is disabled
    mcp_disabled = System.get_env("PUP_DISABLE_MCP", "0")

    if mcp_disabled in ["1", "true", "yes", "on"] do
      []
    else
      try do
        CodePuppyControl.MCP.Manager.list_servers()
      rescue
        _ ->
          Logger.debug("Lifecycle: MCP manager unavailable, returning empty servers")
          []
      end
    end
  end

  @doc """
  Reload MCP servers from configuration.

  Forces a re-sync from mcp_servers.json. Clears any cached tool
  definitions so they are re-fetched on the next run.

  This is the Elixir port of Python's `reload_mcp_servers`.
  """
  @spec reload_mcp_servers() :: [map()]
  def reload_mcp_servers do
    try do
      CodePuppyControl.MCP.Manager.start_all_configured()
      CodePuppyControl.MCP.Manager.list_servers()
    rescue
      _ ->
        Logger.debug("Lifecycle: MCP reload failed, returning empty servers")
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Model Pack Resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolve a model pack role to a concrete model name.

  Delegates to `CodePuppyControl.ModelPacks` if available.
  Falls back to the default model if pack resolution fails.

  ## Examples

      iex> Lifecycle.resolve_pack_model(:coder)
      "claude-sonnet-4-20250514"
  """
  @spec resolve_pack_model(atom()) :: String.t()
  def resolve_pack_model(role) when is_atom(role) do
    try do
      case CodePuppyControl.ModelPacks.get_model_for_role(to_string(role)) do
        {:ok, model_name} -> model_name
        {:error, _reason} -> default_model()
      end
    rescue
      _ ->
        Logger.debug("Lifecycle: model pack resolution not yet implemented for #{inspect(role)}")
        default_model()
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp default_model do
    "claude-sonnet-4-20250514"
  end

  defp global_model_name do
    try do
      CodePuppyControl.Config.Models.global_model_name()
    rescue
      _ -> nil
    end
  end
end
