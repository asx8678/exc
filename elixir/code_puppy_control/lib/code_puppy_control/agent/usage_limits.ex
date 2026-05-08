defmodule CodePuppyControl.Agent.UsageLimits do
  @moduledoc """
  Token and request budgeting for agent runs.

  Port of pydantic-ai's `UsageLimits` dataclass. Provides pre-request
  and post-response limit checks that the agent loop calls before/after
  each LLM turn.

  Unlike the Python version (which raises `UsageLimitExceeded`), the
  Elixir version returns tagged tuples — idiomatic `{:ok, :checked}`
  on success, `{:error, :limit_exceeded, reason}` on failure. This
  lets the agent loop decide how to handle the limit (halt, switch
  model, etc.) without exception control flow.

  ## Design Notes

  * **Pure struct** — no process, no state. The agent loop holds a
    `%UsageLimits{}` alongside its run state.
  * **`nil` means unlimited** — any limit field set to `nil` disables
    that particular check.
  * **Cost in cents** — `cost_limit` is expressed in integer cents
    (not dollars) to match `TokenLedger.Cost` conventions.

  ## Migration from pydantic-ai

  | Python (`UsageLimits`)             | Elixir (`UsageLimits`)              |
  |-------------------------------------|-------------------------------------|
  | `request_limit=50`                 | `request_limit: 50`                |
  | `tool_calls_limit=None`            | `tool_calls_limit: nil`            |
  | `input_tokens_limit=None`          | `input_tokens_limit: nil`          |
  | `output_tokens_limit=None`         | `output_tokens_limit: nil`         |
  | `total_tokens_limit=None`          | `total_tokens_limit: nil`          |
  | (no equivalent)                    | `cost_limit: nil` (cents)          |
  | `check_before_request(usage)`      | `check_before_request(limits, usage)` |
  | raises `UsageLimitExceeded`        | returns `{:error, :limit_exceeded, reason}` |
  """

  alias CodePuppyControl.Agent.RunUsage

  @type limit_reason ::
          :request_limit
          | :tool_calls_limit
          | :input_tokens_limit
          | :output_tokens_limit
          | :total_tokens_limit
          | :cost_limit

  @type t :: %__MODULE__{
          request_limit: non_neg_integer() | nil,
          tool_calls_limit: non_neg_integer() | nil,
          input_tokens_limit: non_neg_integer() | nil,
          output_tokens_limit: non_neg_integer() | nil,
          total_tokens_limit: non_neg_integer() | nil,
          cost_limit: non_neg_integer() | nil
        }

  defstruct [
    :request_limit,
    :tool_calls_limit,
    :input_tokens_limit,
    :output_tokens_limit,
    :total_tokens_limit,
    :cost_limit
  ]

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Creates a new UsageLimits struct from a keyword list.

  All limits default to `nil` (unlimited).

  ## Examples

      iex> limits = UsageLimits.new(request_limit: 50, total_tokens_limit: 100_000)
      iex> limits.request_limit
      50
      iex> limits.total_tokens_limit
      100_000
      iex> limits.input_tokens_limit
      nil
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Checks whether the next LLM request would exceed any limit.

  Call this **before** sending a request to the model. It checks:
  - `request_limit` — has the request count already reached the limit?
  - `tool_calls_limit` — has the tool call count already reached the limit?

  Returns `{:ok, :checked}` if within limits, or
  `{:error, :limit_exceeded, reason}` if a limit would be breached.

  ## Examples

      iex> limits = UsageLimits.new(request_limit: 1)
      iex> usage = RunUsage.new(requests: 0)
      iex> UsageLimits.check_before_request(limits, usage)
      {:ok, :checked}

      iex> limits = UsageLimits.new(request_limit: 1)
      iex> usage = RunUsage.new(requests: 1)
      iex> UsageLimits.check_before_request(limits, usage)
      {:error, :limit_exceeded, :request_limit}
  """
  @spec check_before_request(t(), RunUsage.t()) ::
          {:ok, :checked} | {:error, :limit_exceeded, limit_reason()}
  def check_before_request(%__MODULE__{} = limits, %RunUsage{} = usage) do
    with :ok <- check_limit(limits.request_limit, usage.requests, :request_limit),
         :ok <- check_limit(limits.tool_calls_limit, usage.tool_calls, :tool_calls_limit) do
      {:ok, :checked}
    end
  end

  @doc """
  Checks whether accumulated token usage exceeds any limit.

  Call this **after** receiving an LLM response with updated usage.
  Checks input, output, and total token limits plus cost limit.

  Returns `{:ok, :checked}` if within limits, or
  `{:error, :limit_exceeded, reason}` if a limit is breached.

  ## Examples

      iex> limits = UsageLimits.new(input_tokens_limit: 1000)
      iex> usage = RunUsage.new(input_tokens: 500)
      iex> UsageLimits.check_tokens(limits, usage)
      {:ok, :checked}

      iex> limits = UsageLimits.new(input_tokens_limit: 1000)
      iex> usage = RunUsage.new(input_tokens: 1001)
      iex> UsageLimits.check_tokens(limits, usage)
      {:error, :limit_exceeded, :input_tokens_limit}
  """
  @spec check_tokens(t(), RunUsage.t()) ::
          {:ok, :checked} | {:error, :limit_exceeded, limit_reason()}
  def check_tokens(%__MODULE__{} = limits, %RunUsage{} = usage) do
    with :ok <- check_limit(limits.input_tokens_limit, usage.input_tokens, :input_tokens_limit),
         :ok <- check_limit(limits.output_tokens_limit, usage.output_tokens, :output_tokens_limit),
         :ok <-
           check_limit(
             limits.total_tokens_limit,
             RunUsage.total_tokens(usage),
             :total_tokens_limit
           ) do
      {:ok, :checked}
    end
  end

  @doc """
  Checks whether the accumulated cost exceeds the cost limit.

  The `cost_cents` argument comes from `TokenLedger` rollups.

  ## Examples

      iex> limits = UsageLimits.new(cost_limit: 500)
      iex> UsageLimits.check_cost(limits, 300)
      {:ok, :checked}

      iex> limits = UsageLimits.new(cost_limit: 500)
      iex> UsageLimits.check_cost(limits, 501)
      {:error, :limit_exceeded, :cost_limit}
  """
  @spec check_cost(t(), non_neg_integer()) ::
          {:ok, :checked} | {:error, :limit_exceeded, :cost_limit}
  def check_cost(%__MODULE__{cost_limit: nil}, _cost_cents), do: {:ok, :checked}

  def check_cost(%__MODULE__{cost_limit: limit}, cost_cents) when cost_cents > limit do
    {:error, :limit_exceeded, :cost_limit}
  end

  def check_cost(%__MODULE__{}, _cost_cents), do: {:ok, :checked}

  @doc """
  Returns `true` if any token limits are configured.

  Useful for the agent loop to decide whether it needs to check
  token usage after each streamed response.

  ## Examples

      iex> UsageLimits.has_token_limits?(%UsageLimits{})
      false

      iex> UsageLimits.has_token_limits?(%UsageLimits{input_tokens_limit: 1000})
      true

      iex> UsageLimits.has_token_limits?(%UsageLimits{total_tokens_limit: 50_000})
      true
  """
  @spec has_token_limits?(t()) :: boolean()
  def has_token_limits?(%__MODULE__{} = limits) do
    limits.input_tokens_limit != nil or
      limits.output_tokens_limit != nil or
      limits.total_tokens_limit != nil
  end

  @doc """
  Returns a summary map of all configured limits for logging/display.

  ## Examples

      iex> limits = UsageLimits.new(request_limit: 50, cost_limit: 1000)
      iex> UsageLimits.to_map(limits)
      %{request_limit: 50, tool_calls_limit: nil, input_tokens_limit: nil,
        output_tokens_limit: nil, total_tokens_limit: nil, cost_limit: 1000}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = limits) do
    Map.from_struct(limits)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp check_limit(nil, _current, _reason), do: :ok

  defp check_limit(limit, current, reason) when current >= limit do
    {:error, :limit_exceeded, reason}
  end

  defp check_limit(_limit, _current, _reason), do: :ok
end
