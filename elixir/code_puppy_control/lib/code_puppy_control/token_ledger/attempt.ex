defmodule CodePuppyControl.TokenLedger.Attempt do
  @moduledoc """
  A single LLM request attempt with token accounting.

  Port of Python `TokenAttempt` dataclass. Records both heuristic estimates
  and provider-reported actuals for every LLM request attempt.

  ## Fields

    * `run_id` — Unique identifier for the agent run.
    * `session_id` — Session this attempt belongs to (may be nil).
    * `model` — Model name used for this attempt.
    * `prompt_tokens` — Actual input tokens from provider (0 if unavailable).
    * `completion_tokens` — Actual output tokens from provider (0 if unavailable).
    * `cached_tokens` — Tokens served from provider cache (0 if unavailable).
    * `total_tokens` — Sum of prompt + completion tokens.
    * `cost_cents` — Computed cost in cents for this attempt.
    * `timestamp` — Unix timestamp (millisecond precision) of the attempt.
    * `status` — `:ok` for success, `:error` for failure.
  """

  @type status :: :ok | :error

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_id: String.t() | nil,
          model: String.t(),
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          cached_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost_cents: non_neg_integer(),
          timestamp: integer(),
          status: status()
        }

  @enforce_keys [:run_id, :model]
  defstruct [
    :run_id,
    :session_id,
    :model,
    prompt_tokens: 0,
    completion_tokens: 0,
    cached_tokens: 0,
    total_tokens: 0,
    cost_cents: 0,
    timestamp: nil,
    status: :ok
  ]

  @doc """
  Creates a new Attempt with computed total_tokens and timestamp.

  ## Examples

      iex> attempt = Attempt.new("run-1", "claude-sonnet-4-20250514",
      ...>   prompt_tokens: 100, completion_tokens: 50, cached_tokens: 20)
      iex> attempt.total_tokens
      150
      iex> attempt.prompt_tokens
      100
      iex> attempt.cached_tokens
      20
      iex> attempt.status
      :ok
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(run_id, model, opts \\ []) do
    prompt = Keyword.get(opts, :prompt_tokens, 0)
    completion = Keyword.get(opts, :completion_tokens, 0)
    cached = Keyword.get(opts, :cached_tokens, 0)

    %__MODULE__{
      run_id: run_id,
      session_id: Keyword.get(opts, :session_id),
      model: model,
      prompt_tokens: prompt,
      completion_tokens: completion,
      cached_tokens: cached,
      total_tokens: prompt + completion,
      cost_cents: Keyword.get(opts, :cost_cents, 0),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond)),
      status: Keyword.get(opts, :status, :ok)
    }
  end

  @doc """
  Converts an Attempt to a serializable map.

  ## Examples

      iex> attempt = Attempt.new("run-1", "gpt-4o", prompt_tokens: 10)
      iex> map = Attempt.to_map(attempt)
      iex> map["run_id"]
      "run-1"
      iex> map["prompt_tokens"]
      10
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = attempt) do
    %{
      "run_id" => attempt.run_id,
      "session_id" => attempt.session_id,
      "model" => attempt.model,
      "prompt_tokens" => attempt.prompt_tokens,
      "completion_tokens" => attempt.completion_tokens,
      "cached_tokens" => attempt.cached_tokens,
      "total_tokens" => attempt.total_tokens,
      "cost_cents" => attempt.cost_cents,
      "timestamp" => attempt.timestamp,
      "status" => attempt.status
    }
  end
end
