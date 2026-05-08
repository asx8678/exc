defmodule CodePuppyControl.Stream.Normalizer do
  @moduledoc """
  Bridge between LLM provider events and canonical stream events.

  Wraps a callback function so that raw LLM provider events are converted
  to canonical `CodePuppyControl.Stream.Event` structs before the callback
  receives them.

  ## Design

  The Normalizer handles two event formats:

  1. **Provider events** — `{:part_start, map}`, `{:part_delta, map}`,
     `{:part_end, map}`, `{:done, response}` (from OpenAI/Anthropic providers)
  2. **Legacy events** — `{:text, chunk}`, `{:tool_call, name, args, id}`,
     `{:done, reason}` (from mock/test LLM modules)

  Both are normalized to `{:stream, canonical_event}` tuples.

  ## Usage

      # Wrap the Agent.Loop callback
      raw_callback = fn event -> ... end
      normalized = Normalizer.normalize(raw_callback)

      # Now call with provider events — callback receives canonical events
      normalized.({:part_delta, %{type: :text, index: 0, text: "Hi"}})
      #=> raw_callback receives {:stream, %TextDelta{index: 0, text: "Hi"}}
  """

  alias CodePuppyControl.Stream.Event

  @doc """
  Wraps a callback function to normalize incoming LLM events.

  Returns a new callback that converts raw LLM events to canonical events
  before forwarding them as `{:stream, canonical_event}` tuples.

  Unknown events are passed through unchanged (forward-compatible).
  """
  @spec normalize((term() -> any())) :: (term() -> any())
  def normalize(callback_fn) when is_function(callback_fn, 1) do
    fn event ->
      case convert(event) do
        {:ok, canonical} -> callback_fn.({:stream, canonical})
        :skip -> callback_fn.(event)
      end
    end
  end

  @doc """
  Converts a single raw event to a canonical event.

  Returns `{:ok, canonical_event}` or `:skip` for unrecognized events.

  This is useful when you need direct conversion without wrapping a callback.
  """
  @spec convert(term()) :: {:ok, Event.canonical()} | :skip
  def convert(event) do
    case Event.from_llm(event) do
      {:ok, _} = ok ->
        ok

      :skip ->
        convert_legacy(event)
    end
  end

  # ── Legacy Format Conversion ──────────────────────────────────────────────

  # Legacy: {:text, chunk}
  defp convert_legacy({:text, chunk}) when is_binary(chunk) do
    {:ok, %Event.TextDelta{index: 0, text: chunk}}
  end

  # Legacy: {:tool_call, name, arguments, id}
  defp convert_legacy({:tool_call, name, arguments, id}) do
    args_str =
      case arguments do
        str when is_binary(str) -> str
        other -> Jason.encode!(other)
      end

    {:ok,
     %Event.ToolCallEnd{
       index: 0,
       id: id || "",
       name: to_string(name),
       arguments: args_str
     }}
  end

  # Legacy: {:done, reason}
  defp convert_legacy({:done, _reason}) do
    {:ok, %Event.Done{id: nil, model: nil, finish_reason: nil, usage: nil}}
  end

  defp convert_legacy(_), do: :skip
end
