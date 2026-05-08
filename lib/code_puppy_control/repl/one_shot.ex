defmodule CodePuppyControl.REPL.OneShot do
  @moduledoc """
  One-shot prompt runner for non-interactive CLI invocations.

  Executes a single prompt through the full dispatch pipeline
  (resolve agent → ensure state → append → dispatch → persist → autosave)
  and returns `:ok` or `:error` without starting the interactive REPL loop.

  Extracted from `REPL.Loop` to keep that module under the 600-line cap
  and to maintain a clean API boundary — `Loop.send_to_agent/2` remains
  private to the interactive loop.

  ## Options

    * `:prompt` — The user prompt text (required)
    * `:model` — Model override (default: from config)
    * `:agent` — Agent name (default: "code-puppy", nil falls back too)
    * `:session_id` — Session identifier (default: generated)

  ## Returns

    * `:ok` — Prompt dispatched and response persisted/autosaved
    * `:error` — Dispatch failed (unknown agent, LLM error, etc.)
  """

  require Logger

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.Config.Models
  alias CodePuppyControl.REPL.Dispatch
  alias CodePuppyControl.REPL.Loop

  @default_agent "code-puppy"

  @spec run(map()) :: :ok | :error
  def run(opts) when is_map(opts) do
    # Use || so that explicit nil from CLI parser falls back to default.
    agent = opts[:agent] || @default_agent
    model = opts[:model] || Models.global_model_name()
    session_id = opts[:session_id] || generate_session_id()
    prompt = Map.fetch!(opts, :prompt)

    state = %Loop{
      session_id: session_id,
      agent: agent,
      model: model,
      running: true
    }

    dispatch_prompt(prompt, state)
  end

  # ---------------------------------------------------------------------------
  # Private dispatch pipeline
  # ---------------------------------------------------------------------------

  defp dispatch_prompt(prompt, state) do
    with {:ok, agent_key, agent_module} <- Loop.resolve_agent_module(state.agent),
         :ok <- Loop.ensure_agent_state_for(state.session_id, agent_key) do
      messages_before = State.get_messages(state.session_id, agent_key)

      user_msg = %{"role" => "user", "parts" => [%{"type" => "text", "text" => prompt}]}
      :ok = State.append_message(state.session_id, agent_key, user_msg)

      Dispatch.dispatch_after_append(state, agent_key, agent_module, messages_before)
    else
      {:error, {:unknown_agent, name}} ->
        Dispatch.print_agent_error("Unknown agent: #{name}. Use /agent to switch.")
        :error

      {:error, :no_module} ->
        Dispatch.print_agent_error(
          "Agent \"#{state.agent}\" has no backing module. Use /agent to switch."
        )

        :error

      {:error, reason} ->
        Dispatch.print_agent_error("Agent dispatch failed: #{inspect(reason)}")
        :error
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
