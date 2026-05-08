defmodule CodePuppyControl.TokenLedger.Cost do
  @moduledoc """
  Model cost lookup and computation.

  Maintains a table of per-model pricing ($/1M input tokens, $/1M output tokens,
  cached-read discount). Costs are stored as integer cents per million tokens
  to avoid floating-point issues in billing.

  ## Pricing Sources

  Prices are based on published provider rates as of 2026-Q1. Update the
  `cost_for_model/1` function when providers change pricing.

  ## Unknown Models

  Unknown models return 0 cost with a log warning. This prevents billing
  failures when new models are added before the cost table is updated.
  """

  require Logger

  # Cost in cents per million tokens
  # {input_cents_per_1m, output_cents_per_1m, cached_input_cents_per_1m}
  @type model_cost :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Compute cost in cents for a model with given token counts.

  Returns the cost as an integer number of cents.

  ## Examples

      iex> Cost.compute_cost("claude-sonnet-4-20250514", 1_000_000, 500_000, 0)
      450

      iex> Cost.compute_cost("gpt-4.1", 1_000_000, 1_000_000, 0)
      1000

      iex> Cost.compute_cost("unknown-model", 1_000_000, 1_000_000, 0)
      0
  """
  @spec compute_cost(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def compute_cost(model, prompt_tokens, completion_tokens, cached_tokens \\ 0) do
    {input_rate, output_rate, cached_rate} = cost_for_model(model)

    # Non-cached input tokens
    non_cached_input = max(0, prompt_tokens - cached_tokens)

    # Cost = (non_cached_input * input_rate + cached_input * cached_rate + completion * output_rate) / 1_000_000
    cost =
      non_cached_input * input_rate +
        cached_tokens * cached_rate +
        completion_tokens * output_rate

    # Integer division — round to nearest cent
    div(cost + 500_000, 1_000_000)
  end

  @doc """
  Returns the cost tuple `{input, output, cached}` for a model.

  Unknown models get a warning log and return `{0, 0, 0}`.

  ## Examples

      iex> {input, output, cached} = Cost.cost_for_model("gpt-4o")
      iex> input > 0
      true
  """
  @spec cost_for_model(String.t()) :: model_cost()
  def cost_for_model(model) when is_binary(model) do
    case do_cost_lookup(model) do
      nil ->
        Logger.warning("TokenLedger.Cost: no pricing for model #{inspect(model)}, using 0")
        {0, 0, 0}

      cost ->
        cost
    end
  end

  # ---------------------------------------------------------------------------
  # Model Pricing Table
  # Cents per million tokens: {input, output, cached_input}
  #
  # IMPORTANT: More specific prefixes MUST come before less specific ones.
  # "gpt-4o" must come before "gpt-4" because "gpt-4o" matches "gpt-4" <> _.
  # ---------------------------------------------------------------------------

  # ── Anthropic: exact matches ──
  defp do_cost_lookup("claude-opus-4"), do: {1500, 7500, 150}
  defp do_cost_lookup("claude-sonnet-4-20250514"), do: {300, 1500, 30}
  defp do_cost_lookup("claude-3-5-sonnet-20241022"), do: {300, 1500, 30}
  defp do_cost_lookup("claude-3-5-sonnet-20240620"), do: {300, 1500, 30}
  defp do_cost_lookup("claude-3-5-haiku-20241022"), do: {100, 500, 10}
  defp do_cost_lookup("claude-3-opus-20240229"), do: {1500, 7500, 150}
  defp do_cost_lookup("claude-3-haiku-20240307"), do: {25, 125, 3}
  defp do_cost_lookup("claude-3-sonnet-20240229"), do: {300, 1500, 30}

  # ── Anthropic: prefix matches (versioned) ──
  defp do_cost_lookup("claude-sonnet-4-" <> _), do: {300, 1500, 30}
  defp do_cost_lookup("claude-opus-4-" <> _), do: {1500, 7500, 150}
  defp do_cost_lookup("claude-haiku-4-" <> _), do: {80, 400, 8}
  defp do_cost_lookup("claude-sonnet-4" <> _), do: {300, 1500, 30}
  defp do_cost_lookup("claude-opus-4" <> _), do: {1500, 7500, 150}
  defp do_cost_lookup("claude-haiku-4" <> _), do: {80, 400, 8}
  defp do_cost_lookup("claude-3-5-sonnet" <> _), do: {300, 1500, 30}
  defp do_cost_lookup("claude-3-5-haiku" <> _), do: {100, 500, 10}
  defp do_cost_lookup("claude-3-opus" <> _), do: {1500, 7500, 150}
  defp do_cost_lookup("claude-3-haiku" <> _), do: {25, 125, 3}
  defp do_cost_lookup("claude-3-sonnet" <> _), do: {300, 1500, 30}

  # ── Anthropic: generic prefix (newer/future models) ──
  defp do_cost_lookup("claude-sonnet" <> _), do: {300, 1500, 30}
  defp do_cost_lookup("claude-haiku" <> _), do: {80, 400, 8}
  defp do_cost_lookup("claude-opus" <> _), do: {1500, 7500, 150}

  # ── OpenAI GPT-4.1 family (newest) ──
  defp do_cost_lookup("gpt-4.1-nano" <> _), do: {10, 40, 2}
  defp do_cost_lookup("gpt-4.1-mini" <> _), do: {40, 160, 8}
  defp do_cost_lookup("gpt-4.1" <> _), do: {200, 800, 40}

  # ── OpenAI: exact matches ──
  defp do_cost_lookup("gpt-4o-2024-11-20"), do: {250, 1000, 125}
  defp do_cost_lookup("gpt-4o-2024-08-06"), do: {250, 1000, 125}
  defp do_cost_lookup("gpt-4o-2024-05-13"), do: {500, 1500, 250}
  defp do_cost_lookup("gpt-4o-mini-2024-07-18"), do: {15, 60, 8}
  defp do_cost_lookup("gpt-4-turbo-2024-04-09"), do: {1000, 3000, 500}
  defp do_cost_lookup("gpt-4-0613"), do: {3000, 6000, 1500}
  defp do_cost_lookup("gpt-3.5-turbo-0125"), do: {50, 150, 5}
  defp do_cost_lookup("o1-2024-12-17"), do: {1500, 6000, 750}
  defp do_cost_lookup("o3-mini-2025-01-31"), do: {110, 440, 55}

  # ── OpenAI: MORE SPECIFIC prefix matches first ──
  # "gpt-4.1-nano" before "gpt-4.1-mini" before "gpt-4.1" before "gpt-4o-mini"
  # before "gpt-4o" before "gpt-4-turbo" before "gpt-4"
  defp do_cost_lookup("gpt-4.1-nano" <> _), do: {10, 40, 2}
  defp do_cost_lookup("gpt-4.1-mini" <> _), do: {40, 160, 8}
  defp do_cost_lookup("gpt-4.1" <> _), do: {200, 800, 40}
  defp do_cost_lookup("gpt-4o-mini" <> _), do: {15, 60, 8}
  defp do_cost_lookup("gpt-4o" <> _), do: {250, 1000, 125}
  defp do_cost_lookup("gpt-4-turbo" <> _), do: {1000, 3000, 500}
  defp do_cost_lookup("gpt-4" <> _), do: {3000, 6000, 1500}
  defp do_cost_lookup("gpt-3.5-turbo" <> _), do: {50, 150, 5}

  # ── OpenAI reasoning models ──
  defp do_cost_lookup("o3-mini" <> _), do: {110, 440, 55}
  defp do_cost_lookup("o3" <> _), do: {110, 440, 55}
  defp do_cost_lookup("o1" <> _), do: {1500, 6000, 750}

  # ── ChatGPT Codex (OAuth-backed) models ──
  # (code_puppy-be7) Add chatgpt-gpt-5 prefix entries so unknown-pricing
  # warnings don't pollute escript REPL startup. Pricing is unknown for
  # the OAuth backend; zero cost is acceptable as a placeholder.
  defp do_cost_lookup("chatgpt-gpt-5" <> _), do: {0, 0, 0}
  defp do_cost_lookup("chatgpt-4o" <> _), do: {0, 0, 0}

  # ── Google Gemini ──
  defp do_cost_lookup("gemini-2.5-pro" <> _), do: {125, 1000, 31}
  defp do_cost_lookup("gemini-2.5-flash" <> _), do: {15, 60, 3}
  defp do_cost_lookup("gemini-2.0-flash" <> _), do: {10, 40, 3}
  defp do_cost_lookup("gemini-1.5-pro" <> _), do: {125, 500, 31}
  defp do_cost_lookup("gemini-1.5-flash" <> _), do: {8, 30, 0}
  defp do_cost_lookup("gemini-exp" <> _), do: {125, 500, 31}

  # ── DeepSeek ──
  defp do_cost_lookup("deepseek-r1" <> _), do: {55, 219, 14}
  defp do_cost_lookup("deepseek-v3" <> _), do: {27, 110, 7}
  defp do_cost_lookup("deepseek-coder" <> _), do: {14, 28, 1}
  defp do_cost_lookup("deepseek-chat" <> _), do: {14, 28, 1}

  # ── Catch-all ──
  defp do_cost_lookup(_model), do: nil

  @doc """
  Returns a list of all known model name prefixes.
  Useful for UI display and debugging.
  """
  @spec known_models() :: [String.t()]
  def known_models do
    [
      # Anthropic
      "claude-opus-4",
      "claude-sonnet-4-20250514",
      "claude-haiku-4",
      "claude-3-5-sonnet-20241022",
      "claude-3-5-sonnet-20240620",
      "claude-3-5-haiku-20241022",
      "claude-3-opus-20240229",
      "claude-3-haiku-20240307",
      "claude-3-sonnet-20240229",
      # OpenAI GPT-4.1
      "gpt-4.1",
      "gpt-4.1-mini",
      "gpt-4.1-nano",
      # OpenAI legacy
      "gpt-4o-2024-11-20",
      "gpt-4o-2024-08-06",
      "gpt-4o-2024-05-13",
      "gpt-4o-mini-2024-07-18",
      "gpt-4-turbo-2024-04-09",
      "gpt-4-0613",
      "gpt-3.5-turbo-0125",
      # OpenAI reasoning
      "o1-2024-12-17",
      "o3-mini-2025-01-31",
      # Google Gemini
      "gemini-2.5-pro",
      "gemini-2.5-flash",
      "gemini-2.0-flash",
      "gemini-1.5-pro",
      "gemini-1.5-flash",
      # DeepSeek
      "deepseek-r1",
      "deepseek-v3",
      "deepseek-coder",
      "deepseek-chat",
      # ChatGPT Codex (OAuth)
      "chatgpt-gpt-5",
      "chatgpt-4o"
    ]
  end
end
