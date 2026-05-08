defmodule CodePuppyControl.Messaging.WireEventTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.WireEvent — to_wire/from_wire wrapper helpers.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{WireEvent, Messages}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sample_text_internal(overrides \\ %{}) do
    base = %{
      "level" => "info",
      "text" => "Hello!",
      "is_markdown" => false
    }

    {:ok, msg} = Messages.text_message(Map.merge(base, overrides))
    msg
  end

  # ===========================================================================
  # to_wire/1
  # ===========================================================================

  describe "to_wire/1" do
    test "produces correct wrapper shape with all 5 top-level keys" do
      internal = sample_text_internal(%{"run_id" => "run-1", "session_id" => "sess-1"})
      {:ok, wire} = WireEvent.to_wire(internal)

      assert Map.has_key?(wire, "event_type")
      assert Map.has_key?(wire, "run_id")
      assert Map.has_key?(wire, "session_id")
      assert Map.has_key?(wire, "timestamp")
      assert Map.has_key?(wire, "payload")

      assert Map.keys(wire) |> Enum.sort() ==
               ~w(event_type payload run_id session_id timestamp)
    end

    test "event_type equals category" do
      internal = sample_text_internal(%{"category" => "agent"})
      {:ok, wire} = WireEvent.to_wire(internal)

      assert wire["event_type"] == "agent"
    end

    test "timestamp must be integer — rejects float timestamp_unix_ms" do
      internal = %{
        "id" => "x",
        "category" => "system",
        "level" => "info",
        "text" => "Hi",
        "timestamp_unix_ms" => 1_713_123_456.789
      }

      assert {:error, {:invalid_timestamp_unix_ms, 1_713_123_456.789}} =
               WireEvent.to_wire(internal)
    end

    test "timestamp must be integer — rejects string timestamp_unix_ms" do
      internal = %{
        "id" => "x",
        "category" => "system",
        "level" => "info",
        "text" => "Hi",
        "timestamp_unix_ms" => "12345"
      }

      assert {:error, {:invalid_timestamp_unix_ms, "12345"}} = WireEvent.to_wire(internal)
    end

    test "integer timestamp_unix_ms propagates to wire timestamp" do
      ts = 1_713_123_456_789
      internal = sample_text_internal(%{"timestamp_unix_ms" => ts})
      {:ok, wire} = WireEvent.to_wire(internal)

      assert wire["timestamp"] == ts
      assert is_integer(wire["timestamp"])
    end

    test "payload excludes wrapper fields: run_id, session_id, timestamp, timestamp_unix_ms" do
      internal =
        sample_text_internal(%{
          "run_id" => "run-1",
          "session_id" => "sess-1",
          "timestamp_unix_ms" => 1_713_123_456_789
        })

      {:ok, wire} = WireEvent.to_wire(internal)
      payload = wire["payload"]

      refute Map.has_key?(payload, "run_id")
      refute Map.has_key?(payload, "session_id")
      refute Map.has_key?(payload, "timestamp")
      refute Map.has_key?(payload, "timestamp_unix_ms")
      refute Map.has_key?(payload, "event_type")
    end

    test "payload includes id, category, level, text, is_markdown" do
      internal = sample_text_internal()
      {:ok, wire} = WireEvent.to_wire(internal)
      payload = wire["payload"]

      assert Map.has_key?(payload, "id")
      assert Map.has_key?(payload, "category")
      assert Map.has_key?(payload, "level")
      assert Map.has_key?(payload, "text")
      assert Map.has_key?(payload, "is_markdown")
    end

    test "payload values match internal values" do
      internal = sample_text_internal(%{"is_markdown" => true})
      {:ok, wire} = WireEvent.to_wire(internal)
      payload = wire["payload"]

      assert payload["id"] == internal["id"]
      assert payload["category"] == internal["category"]
      assert payload["level"] == internal["level"]
      assert payload["text"] == internal["text"]
      assert payload["is_markdown"] == true
    end

    test "run_id and session_id propagate to wrapper even when nil" do
      internal = sample_text_internal()
      {:ok, wire} = WireEvent.to_wire(internal)

      assert wire["run_id"] == nil
      assert wire["session_id"] == nil
    end

    test "generates timestamp when timestamp_unix_ms is absent" do
      # Build internal map manually without timestamp_unix_ms
      internal = %{
        "id" => "test-id",
        "category" => "system",
        "level" => "info",
        "text" => "Hi",
        "is_markdown" => false
      }

      before = System.system_time(:millisecond)
      {:ok, wire} = WireEvent.to_wire(internal)
      after_ms = System.system_time(:millisecond)

      assert wire["timestamp"] >= before
      assert wire["timestamp"] <= after_ms
    end

    test "rejects missing category" do
      internal = %{"id" => "x", "level" => "info", "text" => "Hi"}
      assert {:error, :missing_category} = WireEvent.to_wire(internal)
    end

    test "rejects invalid category" do
      internal = %{"id" => "x", "category" => "bogus", "level" => "info", "text" => "Hi"}
      assert {:error, {:invalid_category, "bogus"}} = WireEvent.to_wire(internal)
    end

    test "rejects invalid level when present" do
      internal = %{"id" => "x", "category" => "system", "level" => "yolo", "text" => "Hi"}
      assert {:error, {:invalid_level, "yolo"}} = WireEvent.to_wire(internal)
    end

    test "accepts messages without level (non-TextMessage)" do
      internal = %{"id" => "x", "category" => "divider"}
      {:ok, wire} = WireEvent.to_wire(internal)

      assert wire["event_type"] == "divider"
    end

    test "rejects present nil level (key exists but value is nil)" do
      internal = %{"id" => "x", "category" => "system", "level" => nil, "text" => "Hi"}
      assert {:error, {:invalid_level, nil}} = WireEvent.to_wire(internal)
    end

    test "rejects atom keys in internal map" do
      internal = %{id: "x", category: "system", level: "info", text: "Hi"}
      assert {:error, {:non_string_key, key}} = WireEvent.to_wire(internal)
      assert key in [:id, :category, :level, :text]
    end

    test "rejects non-map input" do
      assert {:error, {:not_a_map, "string"}} = WireEvent.to_wire("string")
      assert {:error, {:not_a_map, nil}} = WireEvent.to_wire(nil)
    end
  end

  # ===========================================================================
  # from_wire/1
  # ===========================================================================

  describe "from_wire/1" do
    test "reconstructs internal map from valid wire envelope" do
      wire = %{
        "event_type" => "system",
        "run_id" => "run-1",
        "session_id" => "sess-1",
        "timestamp" => 1_713_123_456_789,
        "payload" => %{
          "id" => "msg-1",
          "category" => "system",
          "level" => "info",
          "text" => "Hello",
          "is_markdown" => false
        }
      }

      {:ok, internal} = WireEvent.from_wire(wire)

      assert internal["category"] == "system"
      assert internal["level"] == "info"
      assert internal["text"] == "Hello"
      assert internal["id"] == "msg-1"
      assert internal["is_markdown"] == false
      assert internal["run_id"] == "run-1"
      assert internal["session_id"] == "sess-1"
      assert internal["timestamp_unix_ms"] == 1_713_123_456_789
    end

    test "rejects unknown event_type" do
      wire = %{
        "event_type" => "unknown_cat",
        "run_id" => nil,
        "session_id" => nil,
        "timestamp" => 1000,
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:invalid_category, "unknown_cat"}} = WireEvent.from_wire(wire)
    end

    test "rejects missing payload" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000
      }

      assert {:error, {:missing_field, "payload"}} = WireEvent.from_wire(wire)
    end

    test "rejects non-map payload" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => "not a map"
      }

      assert {:error, {:invalid_payload, "not a map"}} = WireEvent.from_wire(wire)
    end

    test "rejects list payload" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => [1, 2, 3]
      }

      assert {:error, {:invalid_payload, [1, 2, 3]}} = WireEvent.from_wire(wire)
    end

    test "rejects missing event_type" do
      wire = %{
        "timestamp" => 1000,
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:missing_field, "event_type"}} = WireEvent.from_wire(wire)
    end

    test "rejects missing timestamp" do
      wire = %{
        "event_type" => "system",
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:missing_field, "timestamp"}} = WireEvent.from_wire(wire)
    end

    test "rejects non-numeric timestamp" do
      wire = %{
        "event_type" => "system",
        "timestamp" => "not-a-number",
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:invalid_timestamp, "not-a-number"}} = WireEvent.from_wire(wire)
    end

    test "rejects nil timestamp" do
      wire = %{
        "event_type" => "system",
        "timestamp" => nil,
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:invalid_timestamp, nil}} = WireEvent.from_wire(wire)
    end

    test "rejects float timestamp (with fractional part)" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1_713_123_456.789,
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:invalid_timestamp, 1_713_123_456.789}} = WireEvent.from_wire(wire)
    end

    test "rejects float timestamp that looks like integer (1000.0)" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000.0,
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:invalid_timestamp, 1000.0}} = WireEvent.from_wire(wire)
    end

    test "rejects non-map input" do
      assert {:error, {:not_a_map, "nope"}} = WireEvent.from_wire("nope")
      assert {:error, {:not_a_map, 42}} = WireEvent.from_wire(42)
    end

    test "handles nil run_id and session_id gracefully" do
      wire = %{
        "event_type" => "system",
        "run_id" => nil,
        "session_id" => nil,
        "timestamp" => 1000,
        "payload" => %{"id" => "msg-1", "category" => "system"}
      }

      {:ok, internal} = WireEvent.from_wire(wire)

      assert internal["run_id"] == nil
      assert internal["session_id"] == nil
    end

    test "payload category is overridden by event_type" do
      # If payload has a different category, event_type wins
      wire = %{
        "event_type" => "agent",
        "timestamp" => 1000,
        "payload" => %{"id" => "msg-1", "category" => "system"}
      }

      {:ok, internal} = WireEvent.from_wire(wire)

      # event_type is the authoritative category
      assert internal["category"] == "agent"
    end
  end

  # ===========================================================================
  # Round-trip: to_wire → from_wire
  # ===========================================================================

  describe "round-trip to_wire → from_wire" do
    test "TextMessage round-trip preserves all fields" do
      original =
        sample_text_internal(%{
          "run_id" => "run-abc",
          "session_id" => "sess-xyz",
          "is_markdown" => true
        })

      {:ok, wire} = WireEvent.to_wire(original)
      {:ok, restored} = WireEvent.from_wire(wire)

      # These survive round-trip
      assert restored["id"] == original["id"]
      assert restored["category"] == original["category"]
      assert restored["level"] == original["level"]
      assert restored["text"] == original["text"]
      assert restored["is_markdown"] == original["is_markdown"]
      assert restored["run_id"] == original["run_id"]
      assert restored["session_id"] == original["session_id"]
      assert restored["timestamp_unix_ms"] == original["timestamp_unix_ms"]
    end

    test "BaseMessage (divider) round-trip" do
      {:ok, original} = Messages.base_message(%{"category" => "divider"})
      {:ok, wire} = WireEvent.to_wire(original)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["id"] == original["id"]
      assert restored["category"] == "divider"
    end

    test "round-trip with all categories" do
      for cat <- ~w(system tool_output agent user_interaction divider) do
        {:ok, original} = Messages.base_message(%{"category" => cat})
        {:ok, wire} = WireEvent.to_wire(original)
        {:ok, restored} = WireEvent.from_wire(wire)

        assert restored["category"] == cat
      end
    end
  end
end
