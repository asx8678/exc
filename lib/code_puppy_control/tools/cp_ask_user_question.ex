defmodule CodePuppyControl.Tools.CpAskUserQuestion do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrapper for the ask_user_question tool.

  Exposes interactive user-question functionality through the Tool
  behaviour so the CodePuppy agent can call `cp_ask_user_question` via
  the tool registry.

  ## Event Protocol Flow

  When invoked from the Elixir agent loop:

  1. Subscribes to the run topic (BEFORE broadcasting to avoid races).
  2. Emits an `ask_user_question_request` wire event (category: `user_interaction`)
     via the EventBus, carrying validated question payloads.
  3. Waits with a fixed monotonic deadline for an `AskUserQuestionResponse`
     command matching the `prompt_id`. Unrelated events are ignored.
  4. Unsubscribes (guaranteed via try/after) and returns `{:ok, result}`.

  When the bridge / TUI is not available (non-interactive environments),
  returns `{:ok, error_response}` so the agent can make a reasonable decision.

  Refs: code_puppy-mmk.7 (Phase E event protocol port)
  """

  use CodePuppyControl.Tool

  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Messaging.{UserInteraction, Commands}

  @default_timeout_ms 300_000

  @impl true
  def name, do: :cp_ask_user_question

  @impl true
  def description do
    "Ask the user multiple related questions in an interactive TUI. " <>
      "Each question should include: 'question' (string), 'header' " <>
      "(short string), optional 'multi_select' (boolean), and 'options' " <>
      "(array of option objects with 'label' and optional 'description')."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "questions" => %{
          "type" => "array",
          "description" =>
            "Array of question objects. Each question should include: " <>
              "'question' (string), 'header' (short string), optional " <>
              "'multi_select' (boolean), and 'options' (array of option " <>
              "objects with 'label' and optional 'description').",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "question" => %{"type" => "string"},
              "header" => %{"type" => "string"},
              "multi_select" => %{"type" => "boolean"},
              "options" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "label" => %{"type" => "string"},
                    "description" => %{"type" => "string"}
                  },
                  "required" => ["label"]
                },
                "minItems" => 2,
                "maxItems" => 6
              }
            },
            "required" => ["question", "header", "options"]
          },
          "minItems" => 1,
          "maxItems" => 10
        }
      },
      "required" => ["questions"]
    }
  end

  @doc """
  Returns the tool-specific timeout in milliseconds.

  Overrides the Tool.Runner default of 60 s because user interaction
  may take up to 5 minutes. The Runner picks this up automatically
  when the module exports `tool_timeout/0`.
  """
  @spec tool_timeout() :: pos_integer()
  def tool_timeout, do: @default_timeout_ms

  @impl true
  def invoke(args, context) do
    run_id = Map.get(context, :run_id)
    session_id = Map.get(context, :session_id)
    timeout = Map.get(context, :timeout, @default_timeout_ms)
    questions_raw = Map.get(args, "questions", [])

    prompt_id = generate_prompt_id()

    with {:ok, request_msg} <-
           UserInteraction.ask_user_question_request(%{
             "prompt_id" => prompt_id,
             "questions" => questions_raw,
             "run_id" => run_id,
             "session_id" => session_id
           }) do
      # Subscribe BEFORE broadcasting to avoid fast-response race
      :ok = EventBus.subscribe_run(run_id)

      try do
        :ok = broadcast_request(run_id, session_id, request_msg)
        wait_for_response(run_id, prompt_id, timeout)
      after
        # Guaranteed cleanup regardless of how we exit
        :ok = EventBus.unsubscribe_run(run_id)
      end
    else
      {:error, reason} ->
        {:ok, build_error_response(reason)}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp generate_prompt_id do
    :crypto.strong_rand_bytes(12)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  defp broadcast_request(run_id, session_id, request_msg) do
    case EventBus.broadcast_message(run_id, session_id, request_msg) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Single-subscription wait loop with fixed monotonic deadline.
  # Unrelated / mismatched events are ignored (not terminal errors).
  # The after-clause guarantees timeout; the deadline prevents unrelated
  # events from resetting the timer indefinitely.
  #
  # `timeout_ms` is carried separately from `deadline` so the timeout
  # response can report the *configured* duration, not monotonic time.
  defp wait_for_response(run_id, prompt_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    spin_wait(run_id, prompt_id, deadline, timeout_ms)
  end

  defp spin_wait(run_id, prompt_id, deadline, timeout_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:ok, build_timeout_response(div(timeout_ms, 1000))}
    else
      result =
        receive do
          {:event, %{type: "command", command: command_wire}} ->
            case try_handle_command(command_wire, prompt_id) do
              {:match, response} ->
                {:ok, response}

              :ignore ->
                # Mismatched or unrelated command — keep waiting
                :continue
            end

          {:event, _other} ->
            # Non-command event — keep waiting
            :continue
        after
          remaining ->
            {:ok, build_timeout_response(div(timeout_ms, 1000))}
        end

      case result do
        :continue -> spin_wait(run_id, prompt_id, deadline, timeout_ms)
        final -> final
      end
    end
  end

  # Try to match a command response. Returns {:match, formatted} on a
  # matching AskUserQuestionResponse, :ignore for anything else
  # (mismatched prompt_id, wrong command type, etc.).
  defp try_handle_command(command_wire, expected_prompt_id) do
    with {:ok, command} <- Commands.from_wire(command_wire),
         :ok <- verify_prompt_id(command, expected_prompt_id) do
      {:match, format_response(command)}
    else
      {:error, {:prompt_id_mismatch, _, _}} -> :ignore
      {:error, :not_ask_user_question_response} -> :ignore
      {:error, _reason} -> :ignore
    end
  end

  defp verify_prompt_id(%Commands.AskUserQuestionResponse{prompt_id: pid}, expected_pid) do
    if pid == expected_pid do
      :ok
    else
      {:error, {:prompt_id_mismatch, expected: expected_pid, got: pid}}
    end
  end

  defp verify_prompt_id(_other, _expected) do
    {:error, :not_ask_user_question_response}
  end

  defp format_response(%Commands.AskUserQuestionResponse{} = cmd) do
    answers =
      case cmd.answers do
        nil ->
          []

        list when is_list(list) ->
          Enum.map(list, fn answer ->
            %{
              "question_header" => Map.get(answer, "question_header", ""),
              "selected_options" => Map.get(answer, "selected_options", []),
              "other_text" => Map.get(answer, "other_text")
            }
          end)
      end

    %{
      "answers" => answers,
      "cancelled" => cmd.cancelled || false,
      "error" => cmd.error,
      "timed_out" => cmd.timed_out || false
    }
  end

  defp build_error_response(reason) do
    %{
      "answers" => [],
      "cancelled" => false,
      "error" => "ask_user_question failed: #{inspect(reason)}",
      "timed_out" => false
    }
  end

  defp build_timeout_response(timeout_seconds) do
    %{
      "answers" => [],
      "cancelled" => false,
      "error" => "Interaction timed out after #{timeout_seconds} seconds of inactivity",
      "timed_out" => true
    }
  end
end
