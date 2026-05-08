defmodule CodePuppyControl.Agent.RunUsage do
  @moduledoc """
  LLM usage tracking for a single agent run.

  Port of pydantic-ai's `RunUsage` dataclass. Accumulates token counts,
  request counts, and tool call counts across all LLM turns in a run.

  ## Design Notes

  * **Pure struct** — no GenServer, no ETS. The agent loop holds a single
    `%RunUsage{}` and merges in each request's usage via `merge/2`.
  * **Integer tokens** — all token fields are non-negative integers to
    avoid floating-point drift in billing calculations. Cost computation
    lives in `TokenLedger.Cost`.
  * **`details` map** — extensible field for provider-specific metrics
    (e.g. Anthropic's `cache_creation_input_tokens`).

  ## Migration from pydantic-ai

  | Python (`RunUsage`)                | Elixir (`RunUsage`)           |
  |-------------------------------------|-------------------------------|
  | `usage.requests`                    | `usage.requests`              |
  | `usage.tool_calls`                  | `usage.tool_calls`            |
  | `usage.input_tokens`               | `usage.input_tokens`          |
  | `usage.output_tokens`              | `usage.output_tokens`         |
  | `usage.cache_write_tokens`         | `usage.cache_write_tokens`    |
  | `usage.cache_read_tokens`          | `usage.cache_read_tokens`     |
  | `usage.details`                    | `usage.details`               |
  | `usage + other`                    | `RunUsage.merge(usage, other)`|
  """

  @type t :: %__MODULE__{
          requests: non_neg_integer(),
          tool_calls: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          details: %{String.t() => non_neg_integer()}
        }

  defstruct requests: 0,
            tool_calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
            details: %{}

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Creates a new RunUsage with all counters zeroed.

  ## Examples

      iex> usage = RunUsage.new()
      iex> usage.requests
      0
      iex> usage.input_tokens
      0
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a RunUsage from a keyword list or map, typically parsed
  from an LLM provider response.

  ## Examples

      iex> usage = RunUsage.new(input_tokens: 100, output_tokens: 50, requests: 1)
      iex> usage.input_tokens
      100
      iex> usage.output_tokens
      50
  """
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts), do: struct(__MODULE__, opts)
  def new(opts) when is_map(opts), do: struct(__MODULE__, opts)

  @doc """
  Merges another RunUsage into this one, returning a new RunUsage
  with summed counters.

  Equivalent to pydantic-ai's `RunUsage.__add__` / `RunUsage.incr`.

  ## Examples

      iex> base = RunUsage.new(requests: 1, input_tokens: 100, output_tokens: 50)
      iex> delta = RunUsage.new(requests: 1, input_tokens: 200, output_tokens: 80)
      iex> merged = RunUsage.merge(base, delta)
      iex> merged.requests
      2
      iex> merged.input_tokens
      300
      iex> merged.output_tokens
      130
  """
  @spec merge(t(), t() | map()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = delta) do
    %__MODULE__{
      requests: base.requests + delta.requests,
      tool_calls: base.tool_calls + delta.tool_calls,
      input_tokens: base.input_tokens + delta.input_tokens,
      output_tokens: base.output_tokens + delta.output_tokens,
      cache_write_tokens: base.cache_write_tokens + delta.cache_write_tokens,
      cache_read_tokens: base.cache_read_tokens + delta.cache_read_tokens,
      details: merge_details(base.details, delta.details)
    }
  end

  def merge(%__MODULE__{} = base, delta) when is_map(delta) do
    merge(base, new(delta))
  end

  @doc """
  Returns the total token count (input + output).

  ## Examples

      iex> usage = RunUsage.new(input_tokens: 100, output_tokens: 50)
      iex> RunUsage.total_tokens(usage)
      150
  """
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%__MODULE__{input_tokens: inp, output_tokens: out}) do
    inp + out
  end

  @doc """
  Converts the RunUsage to a plain map for serialization.

  ## Examples

      iex> usage = RunUsage.new(requests: 1)
      iex> map = RunUsage.to_map(usage)
      iex> map["requests"]
      1
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage) do
    %{
      "requests" => usage.requests,
      "tool_calls" => usage.tool_calls,
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_write_tokens" => usage.cache_write_tokens,
      "cache_read_tokens" => usage.cache_read_tokens,
      "total_tokens" => total_tokens(usage),
      "details" => usage.details
    }
  end

  @doc """
  Checks whether any non-zero usage has been recorded.

  ## Examples

      iex> RunUsage.empty?(RunUsage.new())
      true

      iex> RunUsage.empty?(RunUsage.new(requests: 1))
      false
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = usage) do
    usage.requests == 0 and
      usage.tool_calls == 0 and
      usage.input_tokens == 0 and
      usage.output_tokens == 0 and
      usage.cache_write_tokens == 0 and
      usage.cache_read_tokens == 0
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp merge_details(base, delta) do
    Map.merge(base, delta, fn _k, v1, v2 -> v1 + v2 end)
  end
end
