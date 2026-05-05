defmodule CodePuppyControl.Stream.EventPropertyTest do
  @moduledoc """
  Property tests for CodePuppyControl.Stream.Event codec invariants.

  Proves that `to_wire/1` / `from_wire/1` form a lossless round-trip
  for all 11 canonical event types, including through JSON serialization.

  Wave 1 pilot for — these patterns set the convention for
  future property tests in Waves 2–5.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.Stream.Event.{TextStart, TextDelta, TextEnd}
  alias CodePuppyControl.Stream.Event.{ToolCallStart, ToolCallArgsDelta, ToolCallEnd}
  alias CodePuppyControl.Stream.Event.{ThinkingStart, ThinkingDelta, ThinkingEnd}
  alias CodePuppyControl.Stream.Event.{UsageUpdate, Done}

  # ── Shared generators ─────────────────────────────────────────────────────

  defp index_gen, do: non_negative_integer()

  defp maybe_id_gen, do: one_of([constant(nil), string(:alphanumeric, min_length: 1)])

  defp text_gen, do: string(:alphanumeric, min_length: 1)

  defp non_empty_string_gen, do: string(:alphanumeric, min_length: 1)

  defp text_start_gen do
    gen all(
          index <- index_gen(),
          id <- maybe_id_gen()
        ) do
      %TextStart{index: index, id: id}
    end
  end

  defp text_delta_gen do
    gen all(
          index <- index_gen(),
          text <- text_gen()
        ) do
      %TextDelta{index: index, text: text}
    end
  end

  defp text_end_gen do
    gen all(
          index <- index_gen(),
          id <- maybe_id_gen()
        ) do
      %TextEnd{index: index, id: id}
    end
  end

  defp tool_call_start_gen do
    gen all(
          index <- index_gen(),
          id <- maybe_id_gen(),
          name <- maybe_id_gen()
        ) do
      %ToolCallStart{index: index, id: id, name: name}
    end
  end

  defp tool_call_args_delta_gen do
    gen all(
          index <- index_gen(),
          arguments <- text_gen()
        ) do
      %ToolCallArgsDelta{index: index, arguments: arguments}
    end
  end

  defp tool_call_end_gen do
    gen all(
          index <- index_gen(),
          id <- non_empty_string_gen(),
          name <- non_empty_string_gen(),
          arguments <- non_empty_string_gen()
        ) do
      %ToolCallEnd{index: index, id: id, name: name, arguments: arguments}
    end
  end

  defp thinking_start_gen do
    gen all(
          index <- index_gen(),
          id <- maybe_id_gen()
        ) do
      %ThinkingStart{index: index, id: id}
    end
  end

  defp thinking_delta_gen do
    gen all(
          index <- index_gen(),
          text <- text_gen()
        ) do
      %ThinkingDelta{index: index, text: text}
    end
  end

  defp thinking_end_gen do
    gen all(
          index <- index_gen(),
          id <- maybe_id_gen()
        ) do
      %ThinkingEnd{index: index, id: id}
    end
  end

  defp usage_update_gen do
    gen all(
          prompt <- non_negative_integer(),
          completion <- non_negative_integer(),
          total <- non_negative_integer()
        ) do
      %UsageUpdate{prompt_tokens: prompt, completion_tokens: completion, total_tokens: total}
    end
  end

  defp done_gen do
    gen all(
          id <- maybe_id_gen(),
          model <- maybe_id_gen(),
          finish_reason <- maybe_id_gen(),
          usage <- one_of([constant(nil), usage_update_gen()])
        ) do
      %Done{id: id, model: model, finish_reason: finish_reason, usage: usage}
    end
  end

  defp event_gen do
    one_of([
      text_start_gen(),
      text_delta_gen(),
      text_end_gen(),
      tool_call_start_gen(),
      tool_call_args_delta_gen(),
      tool_call_end_gen(),
      thinking_start_gen(),
      thinking_delta_gen(),
      thinking_end_gen(),
      usage_update_gen(),
      done_gen()
    ])
  end

  # ── Property 1: Wire round-trip ───────────────────────────────────────────

  describe "to_wire/from_wire round-trip" do
    property "from_wire(to_wire(event)) == {:ok, event} for all event types" do
      check all(event <- event_gen(), max_runs: 100) do
        assert {:ok, ^event} = event |> Event.to_wire() |> Event.from_wire()
      end
    end
  end

  # ── Property 2: JSON round-trip ──────────────────────────────────────────

  describe "JSON serialization round-trip" do
    property "event survives Jason.encode!/decode! via wire form" do
      check all(event <- event_gen(), max_runs: 100) do
        wire = Event.to_wire(event)
        json = Jason.encode!(wire)
        decoded = Jason.decode!(json)
        assert {:ok, ^event} = Event.from_wire(decoded)
      end
    end
  end

  # ── Property 3: Index non-negative after round-trip ──────────────────────

  # Only events with an :index field are checked. Done and UsageUpdate lack it.
  defp indexed_event_gen do
    one_of([
      text_start_gen(),
      text_delta_gen(),
      text_end_gen(),
      tool_call_start_gen(),
      tool_call_args_delta_gen(),
      tool_call_end_gen(),
      thinking_start_gen(),
      thinking_delta_gen(),
      thinking_end_gen()
    ])
  end

  describe "index invariant" do
    property "index is non-negative after wire round-trip" do
      check all(event <- indexed_event_gen(), max_runs: 100) do
        {:ok, restored} = event |> Event.to_wire() |> Event.from_wire()
        assert restored.index >= 0
      end
    end
  end
end
