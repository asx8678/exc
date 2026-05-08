defmodule CodePuppyControl.Messaging.WireEventValidationTest do
  @moduledoc """
  Validation, malformed-input, and JSON round-trip tests for WireEvent.

  Split from wire_event_test.exs to stay under the 600-line hard cap.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{WireEvent, Messages}

  # ---------------------------------------------------------------------------
  # Helpers (duplicated from WireEventTest — too small to warrant a shared module)
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
  # JSON round-trip via Jason
  # ===========================================================================

  describe "JSON serialization round-trip" do
    test "wire map survives Jason.encode → Jason.decode" do
      internal =
        sample_text_internal(%{
          "run_id" => "run-json",
          "session_id" => "sess-json",
          "is_markdown" => true
        })

      {:ok, wire} = WireEvent.to_wire(internal)

      # All keys must be string keys (JSON-safe)
      assert_all_string_keys(wire)
      assert_all_string_keys(wire["payload"])

      json = Jason.encode!(wire)
      decoded = Jason.decode!(json)

      # Decoded should match original wire
      assert decoded == wire

      # from_wire should accept decoded
      {:ok, internal2} = WireEvent.from_wire(decoded)
      assert internal2["text"] == "Hello!"
      assert internal2["is_markdown"] == true
    end

    test "TextMessage full pipeline: construct → to_wire → JSON → from_wire" do
      {:ok, msg} =
        Messages.text_message(%{
          "level" => "warning",
          "text" => "Beware!",
          "is_markdown" => false,
          "run_id" => "run-full",
          "session_id" => "sess-full"
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      json = Jason.encode!(wire)
      decoded = Jason.decode!(json)
      {:ok, restored} = WireEvent.from_wire(decoded)

      assert restored["level"] == "warning"
      assert restored["text"] == "Beware!"
      assert restored["is_markdown"] == false
      assert restored["run_id"] == "run-full"
      assert restored["session_id"] == "sess-full"
    end
  end

  # ===========================================================================
  # Malformed input
  # ===========================================================================

  describe "malformed input handling" do
    test "to_wire with atom-keyed map rejects non-string keys" do
      internal = %{id: "x", category: "system", level: "info", text: "Hi"}
      assert {:error, {:non_string_key, key}} = WireEvent.to_wire(internal)
      assert key in [:id, :category, :level, :text]
    end

    test "to_wire with mixed atom/string keys rejects non-string keys" do
      internal = %{"id" => "x", "category" => "system", atom_key: "bad"}
      assert {:error, {:non_string_key, :atom_key}} = WireEvent.to_wire(internal)
    end

    test "from_wire with extra top-level keys still works" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "msg-1"},
        "extra_key" => "ignored"
      }

      {:ok, internal} = WireEvent.from_wire(wire)
      assert internal["id"] == "msg-1"
    end

    test "from_wire with integer event_type" do
      wire = %{
        "event_type" => 42,
        "timestamp" => 1000,
        "payload" => %{"id" => "x"}
      }

      assert {:error, {:invalid_category, 42}} = WireEvent.from_wire(wire)
    end

    test "from_wire rejects wrapper field in payload: run_id" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "run_id" => "leaked"}
      }

      assert {:error, {:wrapper_field_in_payload, "run_id"}} = WireEvent.from_wire(wire)
    end

    test "from_wire rejects wrapper field in payload: session_id" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "session_id" => "leaked"}
      }

      assert {:error, {:wrapper_field_in_payload, "session_id"}} = WireEvent.from_wire(wire)
    end

    test "from_wire rejects wrapper field in payload: timestamp" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "timestamp" => 999}
      }

      assert {:error, {:wrapper_field_in_payload, "timestamp"}} = WireEvent.from_wire(wire)
    end

    test "from_wire rejects wrapper field in payload: timestamp_unix_ms" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "timestamp_unix_ms" => 999}
      }

      assert {:error, {:wrapper_field_in_payload, "timestamp_unix_ms"}} =
               WireEvent.from_wire(wire)
    end

    test "from_wire rejects wrapper field in payload: event_type" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "event_type" => "agent"}
      }

      assert {:error, {:wrapper_field_in_payload, "event_type"}} = WireEvent.from_wire(wire)
    end

    test "from_wire rejects non-string keys in payload" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", :atom_key => "bad"}
      }

      assert {:error, {:non_string_key, :atom_key}} = WireEvent.from_wire(wire)
    end

    test "from_wire rejects invalid level in payload" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "level" => "unknown_level"}
      }

      assert {:error, {:invalid_level, "unknown_level"}} = WireEvent.from_wire(wire)
    end

    test "from_wire accepts valid level in payload" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "level" => "info"}
      }

      {:ok, internal} = WireEvent.from_wire(wire)
      assert internal["level"] == "info"
    end

    test "from_wire accepts payload without level (non-TextMessage)" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "category" => "system"}
      }

      {:ok, internal} = WireEvent.from_wire(wire)
      assert internal["id"] == "x"
    end

    test "from_wire rejects present nil level in payload (key exists but value is nil)" do
      wire = %{
        "event_type" => "system",
        "timestamp" => 1000,
        "payload" => %{"id" => "x", "level" => nil}
      }

      assert {:error, {:invalid_level, nil}} = WireEvent.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp assert_all_string_keys(map) when is_map(map) do
    for {key, val} <- map do
      assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      if is_map(val), do: assert_all_string_keys(val)
    end
  end
end
