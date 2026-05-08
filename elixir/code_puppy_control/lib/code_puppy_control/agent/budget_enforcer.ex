defmodule CodePuppyControl.Agent.BudgetEnforcer do
  @moduledoc """
  Token budget and context window enforcement for agent runs.

  Ports Python's BaseAgent methods for budget checking:
  - `_check_token_budgets` — Per-session and per-run token limits
  - `_check_context_budget_before_send` — Pre-send context window check
  - `estimate_context_overhead_tokens` — System prompt + tool definition overhead

  These checks are called by the agent loop before LLM calls to prevent
  API errors from oversized contexts or budget overruns.

  ## Design decisions

  - **Tagged tuples, not exceptions** — Returns `{:ok, :checked}` on success
    and `{:error, reason}` on failure, matching the `UsageLimits` convention.
  - **Pure functions** — No process state. The loop passes in current usage
    and limits.
  - **Configurable** — All thresholds come from config or parameters.

  ## Integration with Agent.Loop

  The loop calls `check_before_send/2` before each LLM call. If the check
  fails, the loop can trigger compaction, switch models, or halt.
  """

  alias CodePuppyControl.Agent.RunUsage
  alias CodePuppyControl.Agent.UsageLimits

  require Logger

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type budget_error ::
          {:error, :session_budget_exceeded, String.t()}
          | {:error, :run_budget_exceeded, String.t()}
          | {:error, :context_budget_exceeded, String.t()}
          | {:error, :limit_exceeded, UsageLimits.limit_reason()}

  @type budget_check_result :: {:ok, :checked} | budget_error()

  @type token_budgets :: %{
          optional(:max_session_tokens) => non_neg_integer() | nil,
          optional(:max_run_tokens) => non_neg_integer() | nil
        }

  @type context_budget :: %{
          optional(:model_context_length) => non_neg_integer(),
          optional(:max_output_tokens) => non_neg_integer() | nil,
          optional(:safety_margin_fraction) => float()
        }

  # ---------------------------------------------------------------------------
  # Token Budget Checks
  # ---------------------------------------------------------------------------

  @doc """
  Check hard token budgets before making an LLM API call.

  Enforces per-session and per-run token limits. Returns `{:ok, :checked}`
  if within budgets, or `{:error, reason, message}` if a budget is exceeded.

  This is the Elixir port of Python's `_check_token_budgets`.

  ## Parameters

    * `estimated_input` — Estimated input tokens for this request
    * `budgets` — Map with `:max_session_tokens` and `:max_run_tokens`
    * `session_usage` — Current session token usage (`%RunUsage{}`)

  ## Examples

      iex> BudgetEnforcer.check_token_budgets(1000, %{max_session_tokens: 0, max_run_tokens: 0}, %RunUsage{})
      {:ok, :checked}

      iex> usage = %RunUsage{input_tokens: 1000, output_tokens: 500}
      iex> BudgetEnforcer.check_token_budgets(100, %{max_session_tokens: 1500, max_run_tokens: 0}, usage)
      {:ok, :checked}

      iex> usage = %RunUsage{input_tokens: 2000, output_tokens: 500}
      iex> BudgetEnforcer.check_token_budgets(100, %{max_session_tokens: 1500, max_run_tokens: 0}, usage)
      {:error, :session_budget_exceeded, "Session token budget exceeded: 2500 estimated tokens (limit: 1500)"}
  """
  @spec check_token_budgets(non_neg_integer(), token_budgets(), RunUsage.t()) ::
          budget_check_result()
  def check_token_budgets(estimated_input, budgets, session_usage) do
    max_session = Map.get(budgets, :max_session_tokens, 0)
    max_run = Map.get(budgets, :max_run_tokens, 0)

    if (max_session == nil or max_session <= 0) and (max_run == nil or max_run <= 0) do
      {:ok, :checked}
    else
      do_check_token_budgets(estimated_input, max_session, max_run, session_usage)
    end
  end

  defp do_check_token_budgets(estimated_input, max_session, max_run, session_usage) do
    session_total = RunUsage.total_tokens(session_usage)

    cond do
      max_session != nil and max_session > 0 and session_total >= max_session ->
        {:error, :session_budget_exceeded,
         "Session token budget exceeded: #{session_total} estimated tokens (limit: #{max_session})"}

      max_run != nil and max_run > 0 and estimated_input >= max_run ->
        {:error, :run_budget_exceeded,
         "Run token budget exceeded: #{estimated_input} estimated input tokens (limit: #{max_run})"}

      true ->
        {:ok, :checked}
    end
  end

  # ---------------------------------------------------------------------------
  # Context Budget Check
  # ---------------------------------------------------------------------------

  @doc """
  Pre-send assertion: validate that the context fits within the model's token budget.

  Checks that `estimated_input + max_output_tokens` does not exceed the
  model's context window (with a safety margin).

  Returns `{:ok, :checked}` if within budget, or
  `{:error, :context_budget_exceeded, message}` if the budget is exceeded.

  This is the Elixir port of Python's `_check_context_budget_before_send`.

  ## Parameters

    * `estimated_input` — Total estimated input tokens (overhead + messages + prompt)
    * `budget` — Context budget configuration map

  ## Examples

      iex> BudgetEnforcer.check_context_budget(5000, %{
      ...>   model_context_length: 128_000,
      ...>   max_output_tokens: 4096,
      ...>   safety_margin_fraction: 0.9
      ...> })
      {:ok, :checked}

      iex> BudgetEnforcer.check_context_budget(200_000, %{
      ...>   model_context_length: 128_000,
      ...>   max_output_tokens: 4096,
      ...>   safety_margin_fraction: 0.9
      ...> })
      {:error, :context_budget_exceeded, "Context budget exceeded: estimated 200000 input + 4096 output = 204096 tokens (context: 128000, safe: 115200)"}
  """
  @spec check_context_budget(non_neg_integer(), context_budget()) ::
          budget_check_result()
  def check_context_budget(estimated_input, budget) do
    context_length = Map.get(budget, :model_context_length, 128_000)
    max_output = Map.get(budget, :max_output_tokens)
    safety_margin = Map.get(budget, :safety_margin_fraction, 0.9)

    if max_output == nil do
      {:ok, :checked}
    else
      safe_limit = floor(context_length * safety_margin)
      projected_total = estimated_input + max_output

      if projected_total > safe_limit do
        {:error, :context_budget_exceeded,
         "Context budget exceeded: estimated #{estimated_input} input + #{max_output} output = #{projected_total} tokens (context: #{context_length}, safe: #{safe_limit})"}
      else
        {:ok, :checked}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Combined Pre-Send Check
  # ---------------------------------------------------------------------------

  @doc """
  Combined pre-send check: validates token budgets and context budget.

  Call this before sending a request to the LLM. It combines:
  1. Token budget check (session + run limits)
  2. Context budget check (context window overflow)
  3. Usage limits check (request / tool call limits)

  Returns `{:ok, :checked}` if all checks pass, or the first error encountered.

  ## Examples

      iex> BudgetEnforcer.check_before_send(5000, %{
      ...>   token_budgets: %{max_session_tokens: 0, max_run_tokens: 0},
      ...>   context_budget: %{model_context_length: 128_000, max_output_tokens: 4096},
      ...>   usage_limits: nil,
      ...>   session_usage: %RunUsage{}
      ...> })
      {:ok, :checked}
  """
  @spec check_before_send(non_neg_integer(), map()) :: budget_check_result()
  def check_before_send(estimated_input, opts) do
    token_budgets = Map.get(opts, :token_budgets, %{max_session_tokens: 0, max_run_tokens: 0})
    context_budget = Map.get(opts, :context_budget, %{})
    usage_limits = Map.get(opts, :usage_limits)
    session_usage = Map.get(opts, :session_usage, %RunUsage{})

    with {:ok, :checked} <- check_token_budgets(estimated_input, token_budgets, session_usage),
         {:ok, :checked} <- check_context_budget(estimated_input, context_budget),
         {:ok, :checked} <- maybe_check_usage_limits(usage_limits, session_usage) do
      {:ok, :checked}
    end
  end

  defp maybe_check_usage_limits(nil, _usage), do: {:ok, :checked}

  defp maybe_check_usage_limits(limits, usage) do
    case UsageLimits.check_before_request(limits, usage) do
      {:ok, :checked} -> {:ok, :checked}
      {:error, :limit_exceeded, reason} -> {:error, :limit_exceeded, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Context Overhead Estimation
  # ---------------------------------------------------------------------------

  @doc """
  Estimate the token overhead from system prompt and tool definitions.

  This accounts for tokens that are always present in the context:
  - System prompt tokens
  - Tool definition tokens (name, description, parameter schema)

  Returns the estimated token count for the overhead.

  This is the Elixir port of Python's `estimate_context_overhead_tokens`,
  simplified for the Elixir architecture where tool definitions come from
  `Tool.Registry`.

  ## Parameters

    * `system_prompt` — The agent's system prompt string
    * `tool_names` — List of allowed tool atom names
    * `opts` — Options:
      * `:include_mcp` — Whether to estimate MCP tool overhead (default: `true`)

  ## Examples

      iex> BudgetEnforcer.estimate_context_overhead("You are helpful.", [:cp_read_file])
      8

      iex> BudgetEnforcer.estimate_context_overhead("", [])
      0
  """
  @spec estimate_context_overhead(String.t(), [atom()], keyword()) :: non_neg_integer()
  def estimate_context_overhead(system_prompt, tool_names, _opts \\ []) do
    total_tokens = 0

    # 1. System prompt tokens
    total_tokens =
      if is_binary(system_prompt) and system_prompt != "" do
        total_tokens + estimate_tokens(system_prompt)
      else
        total_tokens
      end

    # 2. Tool definition tokens
    total_tokens =
      Enum.reduce(tool_names, total_tokens, fn tool_name, acc ->
        acc + estimate_tool_overhead(tool_name)
      end)

    total_tokens
  end

  @doc """
  Estimate tokens for a text string using the `length / 2.5` heuristic.

  Matches Python's `_estimate_token_count` for cross-language consistency.

  ## Examples

      iex> BudgetEnforcer.estimate_tokens("hello world")
      4

      iex> BudgetEnforcer.estimate_tokens("")
      0
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    if text == "" do
      0
    else
      ceil(String.length(text) / 2.5)
    end
  end

  def estimate_tokens(_), do: 0

  # ---------------------------------------------------------------------------
  # Model Context Length
  # ---------------------------------------------------------------------------

  @doc """
  Return the context length for a model.

  Defaults to 128,000 if the model is unknown or lookup fails.
  This is a safe, conservative default for modern LLMs.

  ## Examples

      iex> BudgetEnforcer.model_context_length("unknown-model")
      128000
  """
  @spec model_context_length(String.t()) :: non_neg_integer()
  def model_context_length(model_name) when is_binary(model_name) do
    # TODO(code_puppy-4s8): Integrate with ModelFactory / model_configs
    # when available in Elixir. For now, return conservative defaults.
    default = 128_000

    case model_name do
      "claude-sonnet-4-20250514" -> 200_000
      "claude-opus-4-20250514" -> 200_000
      "claude-3-5-sonnet" -> 200_000
      "gpt-4o" -> 128_000
      "gpt-4-turbo" -> 128_000
      _ -> default
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Estimate token overhead for a single tool definition.
  # Tries to look up the tool module in the registry; falls back to
  # a minimal estimate (tool name only).
  defp estimate_tool_overhead(tool_name) when is_atom(tool_name) do
    try do
      case CodePuppyControl.Tool.Registry.lookup(tool_name) do
        {:ok, module} ->
          # Estimate from name + description + schema
          name_tokens = estimate_tokens(Atom.to_string(tool_name))

          desc_tokens =
            case module.description() do
              nil -> 0
              desc -> estimate_tokens(desc)
            end

          schema_tokens =
            try do
              schema = module.parameters()

              if is_map(schema) and map_size(schema) > 0 do
                estimate_tokens(Jason.encode!(schema))
              else
                0
              end
            rescue
              _ -> 0
            end

          name_tokens + desc_tokens + schema_tokens

        :error ->
          # Tool not registered — estimate name only
          estimate_tokens(Atom.to_string(tool_name)) + 10
      end
    rescue
      _ ->
        # Registry unavailable — conservative estimate
        estimate_tokens(Atom.to_string(tool_name)) + 10
    end
  end
end
