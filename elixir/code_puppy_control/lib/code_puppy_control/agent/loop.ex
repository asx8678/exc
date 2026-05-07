defmodule CodePuppyControl.Agent.Loop do
  @moduledoc """
  GenServer that runs an agent's conversation loop.

  One `Loop` process per agent run. It drives the turn state machine:
  call LLM → stream → dispatch tools → repeat until done or max_turns.

  ## Lifecycle

      # Start a loop for an agent run
      {:ok, pid} = Loop.start_link(MyApp.Agents.ElixirDev, messages,
        run_id: "run-123",
        session_id: "session-456",
        max_turns: 25
      )

      # Run synchronously (blocks until done or error)
      :ok = Loop.run_until_done(pid, 30_000)

      # Or drive manually
      :ok = Loop.run_turn(pid)

  ## Events

  All events are published via `CodePuppyControl.EventBus` on the run topic.
  Subscribe with `EventBus.subscribe_run(run_id)` to receive them.

  ## Supervision

  Started under `CodePuppyControl.Run.Supervisor` (existing DynamicSupervisor).
  No separate supervisor needed — integrates with existing run infrastructure.

  ## LLM Integration

  The default `:llm_module` is `CodePuppyControl.Agent.LLMAdapter` which bridges the
  old `Agent.LLM` behaviour contract (atom tool names, `{:ok, response}` return) to the
  real `CodePuppyControl.LLM` provider contract (schema-map tools, `:ok` return with
  response delivered via `{:done, response}` callback). Tests may pass a mock via
  `opts[:llm_module]`.

  ## Compaction

  Before each LLM call, the loop checks whether the message history has
  grown beyond the compaction threshold. If so, it runs the three-phase
  compaction pipeline (filter, truncate, split) from `Compaction.compact/2`
  to reclaim tokens and keep the context window manageable.

  Compaction is **enabled by default** and configurable via start opts:

      # Disable compaction entirely
      Loop.start_link(agent, messages, compaction_enabled: false)

      # Customize compaction thresholds
      Loop.start_link(agent, messages,
        compaction_opts: [trigger_messages: 100, keep_fraction: 0.3]
      )

  When compaction runs, an `agent_messages_compacted` event is published
  via the EventBus with stats about what was reduced.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Agent.{
    BudgetEnforcer,
    Events,
    Lifecycle,
    MessageProcessor,
    PromptMixin,
    ResponseValidator,
    ToolCallTracker,
    Turn
  }

  alias CodePuppyControl.Agent.Loop.{Compaction, Streaming, ToolDispatch}
  alias CodePuppyControl.Stream.Normalizer
  alias CodePuppyControl.TokenLedger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @typedoc "Options for starting an agent loop"
  @type start_opts :: [
          run_id: String.t(),
          session_id: String.t() | nil,
          max_turns: pos_integer(),
          llm_module: module(),
          metadata: map(),
          compaction_enabled: boolean(),
          compaction_opts: keyword(),
          model: String.t() | nil
        ]

  @doc """
  Starts an agent loop GenServer.

  ## Arguments

    * `agent_module` — Module implementing `Agent.Behaviour`
    * `initial_messages` — Starting message history (list of message maps)
    * `opts` — See `t:start_opts/0`

  ## Returns

    * `{:ok, pid}` — Loop started
    * `{:error, reason}` — Failed to start
  """
  @spec start_link(module(), [map()], start_opts()) :: GenServer.on_start()
  def start_link(agent_module, initial_messages, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, generate_run_id())

    GenServer.start_link(__MODULE__, {agent_module, initial_messages, opts},
      name: via_tuple(run_id)
    )
  end

  @doc """
  Runs one turn of the agent loop.

  Calls the LLM, streams the response, dispatches any tool calls,
  and returns when the turn completes.

  Returns `:ok` if the turn completed, `{:error, reason}` otherwise.
  """
  @spec run_turn(GenServer.server()) :: :ok | {:error, term()}
  def run_turn(pid) do
    GenServer.call(pid, :run_turn, :infinity)
  end

  @doc """
  Runs the agent loop until completion or error.

  Executes turns in a loop, respecting `max_turns`. Returns `:ok` on
  successful completion, `{:error, reason}` on failure or turn limit.

  ## Options

    * `:timeout` — Per-turn timeout in ms (default: `:infinity`)
  """
  @spec run_until_done(GenServer.server(), non_neg_integer() | :infinity) ::
          :ok | {:error, term()}
  def run_until_done(pid, timeout \\ :infinity) do
    GenServer.call(pid, :run_until_done, timeout)
  end

  @doc """
  Gets the current loop state (for debugging/introspection).
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Returns the current message history from the loop.

  Unlike `get_state/1`, this returns the raw message list so callers
  (e.g., the REPL) can write the final conversation back to `Agent.State`
  after `run_until_done/2` completes.
  """
  @spec get_messages(GenServer.server()) :: [map()]
  def get_messages(pid) do
    GenServer.call(pid, :get_messages)
  end

  @doc """
  Cancels the agent run.

  Sends a halt signal so the loop exits after the current operation.
  """
  @spec cancel(GenServer.server()) :: :ok
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  @doc """
  Generates a unique run ID.

  Public so it can be used by `Agent.run/3` for generating IDs
  before starting the loop.
  """
  @spec generate_run_id() :: String.t()
  def generate_run_id do
    base = System.unique_integer([:positive])
    timestamp = System.system_time(:millisecond)
    "agent-#{timestamp}-#{base}"
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp via_tuple(run_id) do
    {:via, Registry, {CodePuppyControl.Run.Registry, {:agent_loop, run_id}}}
  end

  # ---------------------------------------------------------------------------
  # Server State
  # ---------------------------------------------------------------------------

  defstruct [
    :agent_module,
    :run_id,
    :session_id,
    :max_turns,
    :llm_module,
    :metadata,
    :messages,
    :turn,
    :turn_number,
    :agent_state,
    :cancelled,
    :completed,
    :model_override,
    compaction_enabled: true,
    compaction_opts: []
  ]

  @type server_state :: %__MODULE__{
          agent_module: module(),
          run_id: String.t(),
          session_id: String.t() | nil,
          max_turns: pos_integer(),
          llm_module: module(),
          metadata: map(),
          messages: [map()],
          turn: Turn.t() | nil,
          turn_number: non_neg_integer(),
          agent_state: map(),
          cancelled: boolean(),
          completed: boolean(),
          model_override: String.t() | nil,
          compaction_enabled: boolean(),
          compaction_opts: keyword()
        }

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({agent_module, initial_messages, opts}) do
    run_id = Keyword.get(opts, :run_id, generate_run_id())
    session_id = Keyword.get(opts, :session_id)
    max_turns = Keyword.get(opts, :max_turns, 25)
    llm_module = Keyword.get(opts, :llm_module, CodePuppyControl.Agent.LLMAdapter)
    metadata = Keyword.get(opts, :metadata, %{})
    compaction_enabled = Keyword.get(opts, :compaction_enabled, true)
    compaction_opts = Keyword.get(opts, :compaction_opts, [])
    model_override = Keyword.get(opts, :model)

    state = %__MODULE__{
      agent_module: agent_module,
      run_id: run_id,
      session_id: session_id,
      max_turns: max_turns,
      llm_module: llm_module,
      metadata: metadata,
      messages: initial_messages,
      turn: nil,
      turn_number: 0,
      agent_state: %{turn_number: 0, tool_results: []},
      cancelled: false,
      completed: false,
      compaction_enabled: compaction_enabled,
      compaction_opts: compaction_opts,
      model_override: model_override
    }

    # (code_puppy-be7) Downgrade to debug — this fires on every agent
    # loop start and pollutes escript REPL startup logs.
    Logger.debug(
      "Agent.Loop started: agent=#{inspect(agent_module)} run_id=#{run_id} " <>
        "session_id=#{session_id} max_turns=#{max_turns}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:run_turn, _from, state) do
    case execute_turn(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:run_until_done, _from, state) do
    case run_loop(state) do
      {:ok, new_state} -> {:reply, :ok, %{new_state | completed: true}}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    view = %{
      run_id: state.run_id,
      session_id: state.session_id,
      agent_module: state.agent_module,
      turn_number: state.turn_number,
      max_turns: state.max_turns,
      message_count: length(state.messages),
      cancelled: state.cancelled,
      completed: state.completed,
      compaction_enabled: state.compaction_enabled,
      turn: if(state.turn, do: Turn.summary(state.turn), else: nil)
    }

    {:reply, view, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.info("Agent.Loop cancelled: run_id=#{state.run_id}")
    {:noreply, %{state | cancelled: true}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Agent.Loop received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Core Loop Logic
  # ---------------------------------------------------------------------------

  defp run_loop(%__MODULE__{cancelled: true} = state) do
    Logger.info("Agent.Loop stopped by cancellation: run_id=#{state.run_id}")

    Events.publish(
      Events.turn_ended(state.run_id, state.session_id, state.turn_number, :cancelled)
    )

    {:error, :cancelled, state}
  end

  defp run_loop(%__MODULE__{turn_number: n, max_turns: max} = state) when n >= max do
    Logger.info("Agent.Loop reached max_turns=#{max}: run_id=#{state.run_id}")

    Events.publish(
      Events.run_completed(state.run_id, state.session_id, %{reason: :max_turns_reached, turns: n})
    )

    {:ok, state}
  end

  defp run_loop(state) do
    case execute_turn(state) do
      {:ok, %{completed: true} = new_state} ->
        {:ok, new_state}

      {:ok, new_state} ->
        run_loop(new_state)

      {:error, reason, new_state} ->
        Events.publish(Events.run_failed(new_state.run_id, new_state.session_id, reason))
        {:error, reason, new_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Turn Execution
  # ---------------------------------------------------------------------------

  defp execute_turn(state) do
    turn_number = state.turn_number + 1

    # Compact messages if needed before LLM call
    state = Compaction.maybe_compact_messages(state)

    turn = Turn.new(turn_number, state.messages)

    with {:ok, turn} <- Turn.start_llm_call(turn),
         :ok <- Events.publish(Events.turn_started(state.run_id, state.session_id, turn_number)),
         {:ok, turn} <- do_llm_stream(state, turn) do
      handle_turn_result(state, turn, turn_number)
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_llm_stream(state, turn) do
    case Turn.start_streaming(turn) do
      {:ok, turn} ->
        # Use Lifecycle for system prompt assembly (base + puppy rules)
        # then PromptMixin for platform info, identity, and load_prompt callbacks
        context = %{
          session_id: state.session_id,
          run_id: state.run_id,
          messages: state.messages
        }

        {:ok, base_prompt} = Lifecycle.assemble_system_prompt(state.agent_module, context)

        identity = PromptMixin.get_identity(state.agent_module.name(), state.run_id)
        system_prompt = PromptMixin.get_full_system_prompt(base_prompt, identity)

        tools = state.agent_module.allowed_tools()
        model = resolve_model(state)

        # Pre-send budget check via BudgetEnforcer
        estimated_overhead =
          BudgetEnforcer.estimate_context_overhead(system_prompt, tools)

        estimated_input =
          estimated_overhead + MessageProcessor.estimate_batch_tokens(state.messages)

        budget_check =
          BudgetEnforcer.check_before_send(estimated_input, %{
            context_budget: %{
              model_context_length: BudgetEnforcer.model_context_length(model),
              max_output_tokens: 4096
            },
            token_budgets: %{max_session_tokens: 0, max_run_tokens: 0},
            usage_limits: nil
          })

        turn =
          case budget_check do
            {:error, :context_budget_exceeded, msg} ->
              Logger.warning("Agent.Loop: #{msg}")
              # Trigger compaction as a recovery attempt
              _state_compacted = Compaction.compact_messages(state)
              {:ok, failed_turn} = Turn.fail(turn, {:context_budget_exceeded, msg})
              failed_turn

            {:error, reason} ->
              {:ok, failed_turn} = Turn.fail(turn, reason)
              failed_turn

            {:ok, :checked} ->
              turn
          end

        # Re-check: if budget check failed, the turn is already in error state
        if turn.state == :error do
          {:ok, turn}
        else
          raw_callback = Streaming.build_stream_callback(state)
          stream_callback = Normalizer.normalize(raw_callback)

          case state.llm_module.stream_chat(
                 state.messages,
                 tools,
                 [model: model, system_prompt: system_prompt],
                 stream_callback
               ) do
            {:ok, response} ->
              turn = Streaming.accumulate_response(turn, response)
              Turn.start_tool_calls(turn)

            {:error, reason} ->
              Turn.fail(turn, reason)
          end
        end

      error ->
        error
    end
  end

  defp handle_turn_result(state, %{state: :done} = turn, turn_number) do
    state = finalize_turn(state, turn, turn_number)
    Events.publish(Events.turn_ended(state.run_id, state.session_id, turn_number, :done))

    if Turn.has_pending_tools?(turn) == false and turn.accumulated_text != "" do
      # Text-only response, no tools — validate if schema defined, then complete
      case validate_response_if_schema(state, turn) do
        {:ok, _validated} ->
          Events.publish(
            Events.run_completed(state.run_id, state.session_id, %{
              turns: turn_number,
              reason: :text_response
            })
          )

          {:ok, %{state | completed: true}}

        {:error, validation_errors} ->
          {:error, {:validation_failed, validation_errors}, state}
      end
    else
      {:ok, state}
    end
  end

  defp handle_turn_result(state, %{state: :error, error: reason} = turn, turn_number) do
    state = finalize_turn(state, turn, turn_number)
    Events.publish(Events.turn_ended(state.run_id, state.session_id, turn_number, :error))
    {:error, reason, state}
  end

  defp handle_turn_result(state, turn, turn_number) do
    state = finalize_turn(state, turn, turn_number)
    {:ok, state}
  end

  # Validates response against agent's response_schema if defined.
  # Returns {:ok, response} if no schema or validation passes.
  # Returns {:error, errors} if validation fails.
  defp validate_response_if_schema(state, turn) do
    response = %{text: turn.accumulated_text, tool_calls: []}

    schema =
      if function_exported?(state.agent_module, :response_schema, 0) do
        state.agent_module.response_schema()
      else
        nil
      end

    ResponseValidator.validate(response, schema)
  end

  defp finalize_turn(state, turn, turn_number) do
    # (code_puppy-be7.3) Sanitize tool_call IDs before building any
    # messages. A custom llm_module that bypasses LLMAdapter may produce
    # tool calls with empty or invalid IDs. Sanitizing here ensures the
    # assistant message's tool_calls and the tool result messages use
    # matching, valid IDs — both sourced from the same sanitized list.
    turn = %{
      turn
      | pending_tool_calls: ToolDispatch.sanitize_tool_call_ids(turn.pending_tool_calls)
    }

    # Prune any interrupted tool calls from PRIOR turns before building
    # the current turn's messages. Must happen before appending the
    # assistant(tool_calls) message, otherwise the new tool calls
    # appear as interrupted (they have no matching result yet) and
    # get pruned — losing both the assistant tool-call message and
    # the tool result that follows.
    base_messages = ToolCallTracker.prune_interrupted(state.messages)

    # Build the assistant message for this turn.
    #
    # Provider APIs require that tool-result messages are preceded by an
    # assistant message containing the tool_calls that initiated them.
    # Previously we only appended assistant text, which omitted the required
    # assistant(tool_calls) message for tool-call-only turns — breaking
    # conversation history replay on subsequent LLM turns.
    messages =
      cond do
        turn.pending_tool_calls != [] ->
          # Tool calls present: always emit assistant message with tool_calls.
          # Content is nil when the LLM emitted only tool calls (no text).
          assistant_msg = %{
            role: "assistant",
            content: if(turn.accumulated_text != "", do: turn.accumulated_text),
            tool_calls: turn.pending_tool_calls
          }

          base_messages ++ [assistant_msg]

        turn.accumulated_text != "" ->
          base_messages ++ [%{role: "assistant", content: turn.accumulated_text}]

        true ->
          base_messages
      end

    # Dispatch tool calls and collect results
    messages = ToolDispatch.dispatch_tool_calls(state, turn, messages)

    # Extract token usage from the turn's LLM response (if available)
    model = resolve_model(state)

    status =
      case turn.state do
        :error -> :error
        _ -> :ok
      end

    usage = turn.usage || %{}
    prompt_tokens = usage[:prompt_tokens] || usage["prompt_tokens"] || 0
    completion_tokens = usage[:completion_tokens] || usage["completion_tokens"] || 0

    cached_tokens =
      usage[:cached_tokens] || usage["cached_tokens"] || usage[:cache_read_input_tokens] ||
        usage["cache_read_input_tokens"] || 0

    TokenLedger.record_attempt(state.run_id, model,
      session_id: state.session_id,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      cached_tokens: cached_tokens,
      status: status
    )

    %{
      state
      | turn: turn,
        turn_number: turn_number,
        messages: messages,
        agent_state: %{state.agent_state | turn_number: turn_number}
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp resolve_model(%__MODULE__{model_override: override})
       when is_binary(override) and override != "" do
    override
  end

  defp resolve_model(%__MODULE__{agent_module: agent_module}) do
    preference = agent_module.model_preference()
    Lifecycle.resolve_model(nil, preference)
  end
end
