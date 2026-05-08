defmodule CodePuppyControl.PolicyEngine do
  @moduledoc """
  Priority-based policy engine for tool permission decisions.

  Evaluates tool calls against configurable rules sorted by priority.
  Consolidates permission logic from shell_safety and file_permission_handler.

  ## Permission Decisions

  The engine returns one of three decision types:
  - `Allow` - Operation is permitted without further prompting
  - `Deny` - Operation is rejected with an optional reason
  - `AskUser` - Decision is deferred to an interactive user prompt

  ## Policy Rules

  Rules are evaluated in priority order (highest first). The first matching
  rule determines the outcome. Rules support:
  - Tool name patterns (`*` for all tools, or specific name)
  - Command regex patterns (for shell commands)
  - Args regex patterns (for JSON-serialized arguments)

  ## Security

  - Uses allowlist for atom conversion from untrusted JSON input
  - Regex matching includes timeout protection against ReDoS attacks (1 second default)

  ## Examples

      iex> engine = PolicyEngine.get_engine()
      iex> PolicyEngine.add_rule(%PolicyRule{
      ...>   tool_name: "read_file",
      ...>   decision: :allow,
      ...>   priority: 10
      ...> })
      iex> PolicyEngine.check("read_file", %{"path" => "/etc/passwd"})
      %PolicyRule.Allow{}

  """

  use GenServer

  require Logger
  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.PolicyEngine.PolicyRule.{Allow, Deny, AskUser}
  @typedoc "Possible decision atoms"
  @type decision :: :allow | :deny | :ask_user

  @typedoc "Permission decision union type"
  @type permission_decision :: Allow.t() | Deny.t() | AskUser.t()

  # --------------------------------------------------------------------------
  # PolicyEngine State
  # --------------------------------------------------------------------------

  defstruct [
    :rules,
    :default_decision
  ]

  @typedoc "PolicyEngine state"
  @type t :: %__MODULE__{
          rules: [PolicyRule.t()],
          default_decision: decision()
        }

  # --------------------------------------------------------------------------
  # GenServer Client API
  # --------------------------------------------------------------------------

  @doc """
  Starts the PolicyEngine GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if the PolicyEngine process is running.
  """
  @spec running?() :: boolean()
  def running? do
    Process.whereis(__MODULE__) != nil
  end

  @doc """
  Returns the singleton PolicyEngine (creates if needed).

  Thread-safe atomic check-or-create pattern. Handles the race condition
  where two processes could try to start the engine simultaneously.
  """
  @spec get_engine() :: pid()
  def get_engine do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @doc """
  Resets the singleton (useful for testing).
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Evaluates a tool call against policy rules.

  Returns Allow, Deny, or AskUser based on the first matching rule.
  Falls back to default_decision if no rule matches.

  ## Examples

      iex> PolicyEngine.check("read_file", %{"path" => "/etc/passwd"})
      %Allow{}

      iex> PolicyEngine.check("delete_file", %{"path" => "/"})
      %Deny{reason: "Denied by policy (rule from user)"}

  """
  @spec check(tool_name :: String.t(), args :: map() | nil) :: permission_decision()
  def check(tool_name, args \\ nil) do
    GenServer.call(__MODULE__, {:check, tool_name, args})
  end

  @doc """
  Checks only explicit rules; returns nil if no rule matched.

  Unlike check/2, this does not fall back to the configured default
  decision. Returns nil when no rule matches.

  Use this in callbacks that have their own fallback logic.
  """
  @spec check_explicit(tool_name :: String.t(), args :: map() | nil) ::
          permission_decision() | nil
  def check_explicit(tool_name, args \\ nil) do
    GenServer.call(__MODULE__, {:check_explicit, tool_name, args})
  end

  @doc """
  Checks a shell command against explicit rules only; handles compound commands.

  Like check_explicit/2 but handles compound commands by splitting on
  `&&`, `||`, and `;` and returns the most restrictive explicit decision
  across sub-commands.
  """
  @spec check_shell_command_explicit(String.t(), String.t() | nil) :: permission_decision() | nil
  def check_shell_command_explicit(command, cwd \\ nil) do
    GenServer.call(__MODULE__, {:check_shell_command_explicit, command, cwd})
  end

  @doc """
  Checks a shell command, splitting compounds.

  For compound commands (&&, ||, ;), each sub-command is checked
  independently. The most restrictive decision wins:
  Deny > AskUser > Allow.
  """
  @spec check_shell_command(String.t(), String.t() | nil) :: permission_decision()
  def check_shell_command(command, cwd \\ nil) do
    GenServer.call(__MODULE__, {:check_shell_command, command, cwd})
  end

  @doc """
  Adds a single rule to the engine.
  """
  @spec add_rule(PolicyRule.t()) :: :ok
  def add_rule(rule) do
    GenServer.call(__MODULE__, {:add_rule, rule})
  end

  @doc """
  Adds multiple rules to the engine.
  """
  @spec add_rules([PolicyRule.t()]) :: :ok
  def add_rules(rules) when is_list(rules) do
    GenServer.call(__MODULE__, {:add_rules, rules})
  end

  @doc """
  Removes all rules from a specific source.
  """
  @spec remove_rules_by_source(String.t()) :: :ok
  def remove_rules_by_source(source) do
    GenServer.call(__MODULE__, {:remove_rules_by_source, source})
  end

  @doc """
  Returns all current rules (sorted by priority).
  """
  @spec list_rules() :: [PolicyRule.t()]
  def list_rules do
    GenServer.call(__MODULE__, :list_rules)
  end

  @doc """
  Loads rules from a JSON file.

  Returns the count of rules loaded.
  """
  @spec load_rules_from_file(String.t(), String.t() | nil) :: non_neg_integer()
  def load_rules_from_file(path, source \\ nil) do
    GenServer.call(__MODULE__, {:load_rules_from_file, path, source})
  end

  @doc """
  Loads default rules from standard locations.

  Loads from user config (~/.code_puppy/policy.json) then project
  config (./.code_puppy/policy.json).
  """
  @spec load_default_rules() :: non_neg_integer()
  def load_default_rules do
    GenServer.call(__MODULE__, :load_default_rules)
  end

  # --------------------------------------------------------------------------
  # GenServer Server Implementation
  # --------------------------------------------------------------------------

  @impl true
  def init(opts) do
    default = Keyword.get(opts, :default_decision, :ask_user)

    state = %__MODULE__{
      rules: [],
      default_decision: default
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    new_state = %__MODULE__{
      rules: [],
      default_decision: :ask_user
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:check, tool_name, args}, _from, state) do
    decision = do_check(state, tool_name, args, state.default_decision)
    {:reply, decision, state}
  end

  @impl true
  def handle_call({:check_explicit, tool_name, args}, _from, state) do
    decision = do_check_explicit(state, tool_name, args)
    {:reply, decision, state}
  end

  @impl true
  def handle_call({:check_shell_command_explicit, command, cwd}, _from, state) do
    result = do_check_shell_command_explicit(state, command, cwd)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_shell_command, command, cwd}, _from, state) do
    result = do_check_shell_command(state, command, cwd)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:add_rule, rule}, _from, state) do
    # Ensure patterns are compiled
    compiled_rule = ensure_patterns_compiled(rule)
    rules = [compiled_rule | state.rules] |> Enum.sort_by(& &1.priority, :desc)
    {:reply, :ok, %{state | rules: rules}}
  end

  @impl true
  def handle_call({:add_rules, rules}, _from, state) do
    # Ensure all patterns are compiled
    compiled_rules = Enum.map(rules, &ensure_patterns_compiled/1)
    new_rules = (state.rules ++ compiled_rules) |> Enum.sort_by(& &1.priority, :desc)
    {:reply, :ok, %{state | rules: new_rules}}
  end

  @impl true
  def handle_call({:remove_rules_by_source, source}, _from, state) do
    new_rules = Enum.reject(state.rules, &(&1.source == source))
    {:reply, :ok, %{state | rules: new_rules}}
  end

  @impl true
  def handle_call(:list_rules, _from, state) do
    {:reply, state.rules, state}
  end

  @impl true
  def handle_call({:load_rules_from_file, path, source}, _from, state) do
    {count, new_state} = do_load_rules_from_file_and_update(state, path, source)
    {:reply, count, new_state}
  end

  @impl true
  def handle_call(:load_default_rules, _from, state) do
    {count, new_state} = do_load_default_rules(state)
    {:reply, count, new_state}
  end

  # --------------------------------------------------------------------------
  # Private Implementation
  # --------------------------------------------------------------------------

  @doc false
  defp do_check(state, tool_name, args, default) do
    case find_matching_rule(state.rules, tool_name, args) do
      nil -> to_decision(default)
      rule -> to_decision(rule.decision, rule)
    end
  end

  @doc false
  defp do_check_explicit(state, tool_name, args) do
    case find_matching_rule(state.rules, tool_name, args) do
      nil -> nil
      rule -> to_decision(rule.decision, rule)
    end
  end

  @doc false
  defp do_check_shell_command_explicit(state, command, cwd) do
    sub_commands = split_compound_command(command)

    Enum.reduce(sub_commands, nil, fn sub_cmd, most_restrictive ->
      result =
        do_check_explicit(state, "run_shell_command", %{
          "command" => String.trim(sub_cmd),
          "cwd" => cwd
        })

      # Restrictiveness hierarchy: Deny > AskUser > Allow > nil
      cond do
        match?(%Deny{}, result) ->
          result

        match?(%AskUser{}, result) and
            (most_restrictive == nil or match?(%Allow{}, most_restrictive)) ->
          result

        match?(%Allow{}, result) and most_restrictive == nil ->
          result

        true ->
          most_restrictive
      end
    end)
  end

  @doc false
  defp do_check_shell_command(state, command, cwd) do
    sub_commands = split_compound_command(command)

    if length(sub_commands) <= 1 do
      do_check(
        state,
        "run_shell_command",
        %{"command" => command, "cwd" => cwd},
        state.default_decision
      )
    else
      Enum.reduce(sub_commands, %Allow{}, fn sub_cmd, most_restrictive ->
        result =
          do_check(
            state,
            "run_shell_command",
            %{"command" => String.trim(sub_cmd), "cwd" => cwd},
            state.default_decision
          )

        cond do
          match?(%Deny{}, result) ->
            result

          match?(%AskUser{}, result) and match?(%Allow{}, most_restrictive) ->
            result

          true ->
            most_restrictive
        end
      end)
    end
  end

  @doc false
  defp split_compound_command(command) when is_binary(command) do
    # Split on &&, ||, and ;
    Regex.split(~r/\s*(?:&&|\|\||;)\s*/, command, trim: true)
  end

  @doc false
  defp find_matching_rule(rules, tool_name, args) do
    stringified = if args, do: Jason.encode!(args, sort_keys: true), else: nil
    command = get_in(args, ["command"]) || ""

    Enum.find(rules, fn rule ->
      matches_tool?(rule, tool_name) and
        matches_patterns?(rule, command, stringified)
    end)
  end

  @doc false
  defp matches_tool?(%{tool_name: "*"}, _tool_name), do: true
  defp matches_tool?(%{tool_name: rule_tool}, tool_name), do: rule_tool == tool_name

  @doc false
  defp matches_patterns?(rule, command, stringified) do
    # Check command pattern
    command_match =
      cond do
        # No pattern specified - always matches
        rule.command_pattern == nil ->
          true

        # Pattern was specified but failed to compile - treat as no pattern (match)
        rule._command_pattern_valid == false ->
          true

        # Pattern compiled successfully - perform match
        rule._compiled_command != nil ->
          result = safe_regex_match?(rule._compiled_command, to_string(command), 1000)
          # result can be: true (matched), false (no match), :timeout (error)
          result == true

        # Fallback (shouldn't reach here)
        true ->
          true
      end

    # Check args pattern
    args_match =
      cond do
        # No pattern specified - always matches
        rule.args_pattern == nil ->
          true

        # Pattern was specified but failed to compile - treat as no pattern (match)
        rule._args_pattern_valid == false ->
          true

        # Pattern compiled successfully but no args provided - can't match
        rule._compiled_args != nil and stringified == nil ->
          false

        # Pattern compiled successfully - perform match
        rule._compiled_args != nil and stringified != nil ->
          result = safe_regex_match?(rule._compiled_args, stringified, 1000)
          result == true

        # Fallback (shouldn't reach here)
        true ->
          true
      end

    # Both must match for the rule to apply
    command_match and args_match
  end

  @doc false
  # Ensure regex patterns are compiled on a rule
  defp ensure_patterns_compiled(
         %PolicyRule{
           _compiled_command: nil,
           command_pattern: nil,
           _compiled_args: nil,
           args_pattern: nil
         } = rule
       ) do
    # No patterns to compile
    rule
  end

  defp ensure_patterns_compiled(%PolicyRule{} = rule) do
    # Use PolicyRule.new to recompile patterns
    PolicyRule.new(
      tool_name: rule.tool_name,
      decision: rule.decision,
      priority: rule.priority,
      command_pattern: rule.command_pattern,
      args_pattern: rule.args_pattern,
      source: rule.source
    )
  end

  @doc false
  # SECURITY: Timeout-protected regex matching to prevent ReDoS
  defp safe_regex_match?(regex, text, timeout_ms) do
    task =
      Task.async(fn ->
        Regex.match?(regex, text)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      nil ->
        Logger.warning("ReDoS timeout: regex took too long")
        :timeout

      {:ok, result} ->
        result

      {:exit, _reason} ->
        Logger.warning("ReDoS timeout: regex task exited")
        :timeout
    end
  end

  @doc false
  defp to_decision(decision, rule \\ nil) do
    src = if rule, do: " (rule from #{rule.source})", else: ""

    case decision do
      :allow -> %Allow{}
      :deny -> %Deny{reason: "Denied by policy#{src}", user_feedback: nil}
      :ask_user -> %AskUser{prompt: "Policy requires user approval#{src}"}
    end
  end

  @doc false
  defp do_load_rules_from_file_and_update(state, path, source) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            rules_list = if is_list(data), do: data, else: Map.get(data, "rules", [])

            {count, valid_rules} =
              Enum.reduce(rules_list, {0, []}, fn item, {count, rules} ->
                case rule_from_map(item, source || path) do
                  {:ok, rule} -> {count + 1, [rule | rules]}
                  :skip -> {count, rules}
                end
              end)

            # Add rules directly to state (avoid deadlock)
            new_rules =
              (state.rules ++ Enum.reverse(valid_rules)) |> Enum.sort_by(& &1.priority, :desc)

            Logger.info("Loaded #{count} policy rules from #{path}")
            {count, %{state | rules: new_rules}}

          {:error, reason} ->
            Logger.warning("Failed to parse policy rules from #{path}: #{inspect(reason)}")
            {0, state}
        end

      {:error, reason} ->
        Logger.debug("Policy file not found or unreadable #{path}: #{inspect(reason)}")
        {0, state}
    end
  end

  @doc false
  defp do_load_default_rules(state) do
    user_path = Paths.user_policy_file()
    project_path = Paths.project_policy_file()

    {count1, state1} = do_load_rules_from_file_and_update(state, user_path, "user")
    {count2, state2} = do_load_rules_from_file_and_update(state1, project_path, "project")

    {count1 + count2, state2}
  end

  @doc false
  defp rule_from_map(map, source) when is_map(map) do
    tool_name = Map.get(map, "tool_name")

    if is_nil(tool_name) do
      :skip
    else
      rule =
        PolicyRule.new(
          tool_name: tool_name,
          decision: PolicyRule.safe_decision_atom(Map.get(map, "decision", "ask_user")),
          priority: Map.get(map, "priority", 0),
          command_pattern: Map.get(map, "command_pattern"),
          args_pattern: Map.get(map, "args_pattern"),
          source: source
        )

      {:ok, rule}
    end
  end

  defp rule_from_map(_other, _source), do: :skip
end
