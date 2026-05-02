defmodule CodePuppyControl.Agent.Turn do
  @moduledoc """
  Pure state machine for a single agent turn.

  A "turn" is one complete cycle: LLM call → stream → tool dispatch → done.
  This module is pure data — no processes, no side effects. The `Agent.Loop`
  GenServer drives transitions and performs I/O.

  ## State Diagram

  ```
  idle ──→ calling_llm ──→ streaming ──→ tool_calling ──→ tool_awaiting ──→ done
                │                │               │               │
                └────────────────┴───────────────┴───────────────┘
                                        │
                                      error
  ```

  ## Design Notes

  - States are atoms for easy pattern matching in the Loop
  - The struct carries accumulated data for the turn (messages, tool calls, etc.)
  - Transitions are pure functions that return `{:ok, turn}` or `{:error, reason}`
  - No validation beyond what's needed for correct state flow
  """

  @typedoc "Turn lifecycle states"
  @type state ::
          :idle
          | :calling_llm
          | :streaming
          | :tool_calling
          | :tool_awaiting
          | :done
          | :error

  @typedoc "A tool call request from the LLM"
  @type tool_call :: %{
          id: String.t(),
          name: atom(),
          arguments: map()
        }

  @type t :: %__MODULE__{
          state: state(),
          turn_number: non_neg_integer(),
          messages: [map()],
          accumulated_text: String.t(),
          pending_tool_calls: [tool_call()],
          completed_tool_calls: [tool_call()],
          tool_results: [map()],
          usage: map() | nil,
          error: term() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  defstruct [
    :state,
    :turn_number,
    :messages,
    :accumulated_text,
    :pending_tool_calls,
    :completed_tool_calls,
    :tool_results,
    :usage,
    :error,
    :started_at,
    :finished_at
  ]

  @doc """
  Creates a new idle turn with the given turn number and message history.
  """
  @spec new(non_neg_integer(), [map()]) :: t()
  def new(turn_number, messages \\ []) do
    %__MODULE__{
      state: :idle,
      turn_number: turn_number,
      messages: messages,
      accumulated_text: "",
      pending_tool_calls: [],
      completed_tool_calls: [],
      tool_results: [],
      usage: nil,
      error: nil,
      started_at: nil,
      finished_at: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Transition from `:idle` to `:calling_llm`.

  Records the start time for the turn.
  """
  @spec start_llm_call(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def start_llm_call(%__MODULE__{state: :idle} = turn) do
    {:ok, %{turn | state: :calling_llm, started_at: DateTime.utc_now()}}
  end

  def start_llm_call(_turn), do: {:error, :invalid_transition}

  @doc """
  Transition from `:calling_llm` to `:streaming`.

  Called when the LLM starts streaming tokens.
  """
  @spec start_streaming(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def start_streaming(%__MODULE__{state: :calling_llm} = turn) do
    {:ok, %{turn | state: :streaming}}
  end

  def start_streaming(_turn), do: {:error, :invalid_transition}

  @doc """
  Append a text chunk during `:streaming` state.

  Accumulates text content from the LLM stream.
  """
  @spec append_text(t(), String.t()) :: {:ok, t()} | {:error, :invalid_transition}
  def append_text(%__MODULE__{state: :streaming} = turn, chunk) when is_binary(chunk) do
    {:ok, %{turn | accumulated_text: turn.accumulated_text <> chunk}}
  end

  def append_text(_turn, _chunk), do: {:error, :invalid_transition}

  @doc """
  Record a tool call request during `:streaming` state.

  The LLM may request one or more tool calls. Each is accumulated
  for batch dispatch.
  """
  @spec add_tool_call(t(), tool_call()) :: {:ok, t()} | {:error, :invalid_transition}
  def add_tool_call(%__MODULE__{state: :streaming} = turn, %{} = tool_call) do
    {:ok, %{turn | pending_tool_calls: turn.pending_tool_calls ++ [tool_call]}}
  end

  def add_tool_call(_turn, _tool_call), do: {:error, :invalid_transition}

  @doc """
  Transition from `:streaming` to `:tool_calling`.

  Called when the LLM finishes streaming and we have pending tool calls
  to execute. The caller should then dispatch each pending tool call.
  """
  @spec start_tool_calls(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def start_tool_calls(%__MODULE__{state: :streaming} = turn) do
    if turn.pending_tool_calls == [] do
      # No tool calls — skip directly to done
      {:ok, %{turn | state: :done, finished_at: DateTime.utc_now()}}
    else
      {:ok, %{turn | state: :tool_calling}}
    end
  end

  def start_tool_calls(_turn), do: {:error, :invalid_transition}

  @doc """
  Transition from `:tool_calling` to `:tool_awaiting`.

  Signals that all tool calls have been dispatched and we're waiting
  for results.
  """
  @spec await_tools(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def await_tools(%__MODULE__{state: :tool_calling} = turn) do
    {:ok, %{turn | state: :tool_awaiting}}
  end

  def await_tools(_turn), do: {:error, :invalid_transition}

  @doc """
  Record a completed tool result during `:tool_awaiting` state.

  Moves the tool call from pending to completed and stores the result.
  When all pending tool calls are resolved, transitions to `:done`.
  """
  @spec complete_tool(t(), String.t(), term()) :: {:ok, t()} | {:error, :invalid_transition}
  def complete_tool(%__MODULE__{state: :tool_awaiting} = turn, tool_call_id, result) do
    {matched, remaining} =
      Enum.split_with(turn.pending_tool_calls, fn tc -> tc.id == tool_call_id end)

    completed = matched ++ turn.completed_tool_calls
    results = [%{tool_call_id: tool_call_id, result: result} | turn.tool_results]

    new_state = if remaining == [], do: :done, else: :tool_awaiting
    finished_at = if new_state == :done, do: DateTime.utc_now(), else: nil

    {:ok,
     %{
       turn
       | state: new_state,
         pending_tool_calls: remaining,
         completed_tool_calls: completed,
         tool_results: results,
         finished_at: finished_at
     }}
  end

  def complete_tool(_turn, _id, _result), do: {:error, :invalid_transition}

  @doc """
  Transition to `:done` state.

  Used for early termination (e.g. agent decided to halt via `on_tool_result`).
  """
  @spec finish(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def finish(%__MODULE__{state: state} = turn)
      when state in [:streaming, :tool_awaiting, :tool_calling] do
    {:ok, %{turn | state: :done, finished_at: DateTime.utc_now()}}
  end

  def finish(_turn), do: {:error, :invalid_transition}

  @doc """
  Transition to `:error` state with the given reason.
  """
  @spec fail(t(), term()) :: {:ok, t()}
  def fail(%__MODULE__{} = turn, reason) do
    {:ok, %{turn | state: :error, error: reason, finished_at: DateTime.utc_now()}}
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if the turn is in a terminal state (`:done` or `:error`).
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}) when state in [:done, :error], do: true
  def terminal?(_turn), do: false

  @doc """
  Returns true if the turn has pending tool calls to execute.
  """
  @spec has_pending_tools?(t()) :: boolean()
  def has_pending_tools?(%__MODULE__{pending_tool_calls: calls}) do
    calls != []
  end

  @doc """
  Returns the elapsed time for the turn in milliseconds.

  Returns `nil` if the turn hasn't started.
  """
  @spec elapsed_ms(t()) :: non_neg_integer() | nil
  def elapsed_ms(%__MODULE__{started_at: nil}), do: nil

  def elapsed_ms(%__MODULE__{started_at: started, finished_at: nil}) do
    DateTime.diff(DateTime.utc_now(), started, :millisecond)
  end

  def elapsed_ms(%__MODULE__{started_at: started, finished_at: finished}) do
    DateTime.diff(finished, started, :millisecond)
  end

  @doc """
  Returns a summary map for the turn (used in event emission and logging).
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = turn) do
    %{
      turn_number: turn.turn_number,
      state: turn.state,
      text_length: String.length(turn.accumulated_text),
      tool_calls_requested: length(turn.pending_tool_calls) + length(turn.completed_tool_calls),
      tool_calls_completed: length(turn.completed_tool_calls),
      error: turn.error,
      elapsed_ms: elapsed_ms(turn)
    }
  end
end
