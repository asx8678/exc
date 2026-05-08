defmodule CodePuppyControl.LLM.OtelSpanTest do
  @moduledoc """
  OpenTelemetry span attribute tests ported from Python (originally ).

  Covers gap analysis items G30–G35:
  - G30: set_span_attributes when span is recording and model matches
  - G31: set_span_attributes when span is recording but model doesn't match
  - G32: set_span_attributes when span is not recording (no-op)
  - G33: set_span_attributes with empty attributes (no crash)
  - G34: set_span_attributes exception suppression (never crashes the caller)
  - G35: DummySpan / noop span is not recording

  These tests define the expected behavior for `set_span_attributes/3` which
  will be implemented in `CodePuppyControl.Telemetry` when OpenTelemetry is
  integrated into the Elixir stack. Until then, the module under test doesn't
  exist — so all tests are tagged `:skip` with a clear message.

  The target API (mirroring Python's `_set_span_attributes`):

      Telemetry.set_span_attributes(span, round_robin_name, response_model_name)
      |> Telemetry.maybe_set_span_attributes()

  Or more idiomatically:

      Telemetry.set_span_attributes(span, %{
        "gen_ai.request.model" => round_robin_name,
        "gen_ai.response.model" => response_model_name
      })

  The Python implementation:

      def _set_span_attributes(self, model):
          with suppress(Exception):
              span = get_current_span()
              if span.is_recording():
                  attributes = getattr(span, "attributes", {})
                  if attributes.get("gen_ai.request.model") == self.model_name:
                      span.set_attributes({"gen_ai.response.model": model.model_name})

  Key invariants to preserve when implementing:
  1. Exceptions are always suppressed — observability must never crash the request
  2. Attributes are only set when the span is recording
  3. Attributes are only set when gen_ai.request.model matches the round-robin name
  4. A missing `attributes` field on the span must not crash
  5. DummySpan (the no-OTel fallback) reports `is_recording() == false`
  """

  use ExUnit.Case, async: true

  # Skip all tests until OTel is implemented in Elixir.
  # Remove this tag when CodePuppyControl.Telemetry gains set_span_attributes/2,3
  # and a get_current_span/0 that returns a struct with :is_recording, :attributes,
  # :set_attributes.
  @moduletag :otel

  @moduletag skip:
               "OTel not yet implemented in Elixir — enable when CodePuppyControl.Telemetry gains span attribute support"

  # ---------------------------------------------------------------------------
  # Mock / stub span definitions
  # ---------------------------------------------------------------------------
  # These structs define the expected shape of OTel spans once the real
  # implementation lands. When that happens, replace these with the actual
  # structs from the OTel library.

  defmodule RecordingSpan do
    @moduledoc "A mock span that is recording and has configurable attributes."

    defstruct attributes: %{}, set_calls: []

    def new(attrs \\ %{}) do
      %__MODULE__{attributes: attrs, set_calls: []}
    end

    def is_recording(_span), do: true

    def set_attributes(span, new_attrs) when is_map(new_attrs) do
      %{span | set_calls: span.set_calls ++ [new_attrs]}
    end
  end

  defmodule NonRecordingSpan do
    @moduledoc "A mock span that is NOT recording (like a noop / dummy span)."

    defstruct attributes: %{}

    def new(attrs \\ %{}) do
      %__MODULE__{attributes: attrs}
    end

    def is_recording(_span), do: false

    def set_attributes(span, _new_attrs), do: span
  end

  defmodule DummySpan do
    @moduledoc """
    Equivalent of Python's DummySpan — the fallback when opentelemetry
    is not available.

    Always returns `is_recording() == false` and silently ignores
    `set_attributes/2`.
    """

    defstruct []

    def new, do: %__MODULE__{}
    def is_recording(_span), do: false
    def set_attributes(span, _new_attrs), do: span
  end

  defmodule ExplodingSpan do
    @moduledoc "A span whose is_recording/1 always raises — tests exception suppression."

    defstruct []

    def new, do: %__MODULE__{}
    def is_recording(_span), do: raise("boom")
    def set_attributes(_span, _attrs), do: raise("should not reach")
  end

  defmodule LateExplodingSpan do
    @moduledoc "A span whose set_attributes/2 always raises — tests exception suppression."

    defstruct attributes: %{}, set_calls: []

    def new(attrs \\ %{}) do
      %__MODULE__{attributes: attrs, set_calls: []}
    end

    def is_recording(_span), do: true

    def set_attributes(_span, _attrs) do
      raise("kaboom")
    end
  end

  # ---------------------------------------------------------------------------
  # Helper: delegate to the real production integration point
  # ---------------------------------------------------------------------------
  # These tests intentionally target the future production API so they cannot
  # go green against a test-local placeholder implementation.

  defp set_span_attributes(span, round_robin_name, response_model_name) do
    if function_exported?(CodePuppyControl.Telemetry, :set_span_attributes, 3) do
      CodePuppyControl.Telemetry.set_span_attributes(span, round_robin_name, response_model_name)
    else
      raise "CodePuppyControl.Telemetry.set_span_attributes/3 is not implemented yet"
    end
  end

  # ===========================================================================
  # G30: Recording span, model matches → attributes are set
  # ===========================================================================

  describe "G30: set_span_attributes when recording and model matches" do
    test "sets gen_ai.response.model when gen_ai.request.model matches round-robin name" do
      span =
        RecordingSpan.new(%{
          "gen_ai.request.model" => "round_robin:model1,model2"
        })

      result =
        set_span_attributes(
          span,
          "round_robin:model1,model2",
          "model1"
        )

      assert length(result.set_calls) == 1

      assert Enum.at(result.set_calls, 0) == %{
               "gen_ai.response.model" => "model1"
             }
    end

    test "does not set attributes multiple times for the same call" do
      span =
        RecordingSpan.new(%{
          "gen_ai.request.model" => "round_robin:a,b"
        })

      result = set_span_attributes(span, "round_robin:a,b", "a")

      assert length(result.set_calls) == 1
    end
  end

  # ===========================================================================
  # G31: Recording span, model doesn't match → no attributes set
  # ===========================================================================

  describe "G31: set_span_attributes when recording but model doesn't match" do
    test "does not set attributes when gen_ai.request.model differs from round-robin name" do
      span =
        RecordingSpan.new(%{
          "gen_ai.request.model" => "something_else"
        })

      result =
        set_span_attributes(
          span,
          "round_robin:model1,model2",
          "model1"
        )

      assert result.set_calls == []
    end

    test "does not set attributes when gen_ai.request.model is nil" do
      span = RecordingSpan.new(%{})

      result =
        set_span_attributes(
          span,
          "round_robin:model1,model2",
          "model1"
        )

      assert result.set_calls == []
    end

    test "partial match is not a match" do
      span =
        RecordingSpan.new(%{
          "gen_ai.request.model" => "round_robin:model1"
        })

      result =
        set_span_attributes(
          span,
          "round_robin:model1,model2",
          "model1"
        )

      assert result.set_calls == []
    end
  end

  # ===========================================================================
  # G32: Span not recording → no-op
  # ===========================================================================

  describe "G32: set_span_attributes when span is not recording" do
    test "does not set attributes on a non-recording span" do
      span =
        NonRecordingSpan.new(%{
          "gen_ai.request.model" => "round_robin:a,b"
        })

      result = set_span_attributes(span, "round_robin:a,b", "a")

      # NonRecordingSpan.set_attributes/2 is never called because
      # is_recording returns false — the span is returned unchanged.
      assert result == span
    end

    test "returns the span unchanged without any side effects" do
      span = NonRecordingSpan.new(%{})
      result = set_span_attributes(span, "round_robin:x", "x")

      assert result == span
      assert span.__struct__.is_recording(span) == false
    end
  end

  # ===========================================================================
  # G33: Empty / missing attributes on span
  # ===========================================================================

  describe "G33: set_span_attributes with empty or missing attributes" do
    test "handles empty attributes map without crashing" do
      span = RecordingSpan.new(%{})

      result =
        set_span_attributes(
          span,
          "round_robin:model1",
          "model1"
        )

      # No match → no set_attributes call
      assert result.set_calls == []
    end

    test "handles span with no attributes field gracefully" do
      # Create a struct-like map that doesn't have an :attributes key at all
      span = %{__struct__: RecordingSpan, set_calls: []}

      result =
        set_span_attributes(
          span,
          "round_robin:model1",
          "model1"
        )

      # Should not crash — get_request_model returns nil for missing key
      assert result.set_calls == []
    end
  end

  # ===========================================================================
  # G34: Exception suppression — observability must never crash the request
  # ===========================================================================

  describe "G34: set_span_attributes suppresses exceptions" do
    test "does not propagate exceptions from is_recording" do
      span = ExplodingSpan.new()

      # Must not raise — exceptions are suppressed
      result = set_span_attributes(span, "round_robin:a,b", "a")

      # Returns the span (or a safe value) instead of crashing
      assert result != nil
    end

    test "does not propagate exceptions from set_attributes" do
      span = LateExplodingSpan.new(%{"gen_ai.request.model" => "round_robin:x"})

      # Must not raise — even if set_attributes blows up
      result = set_span_attributes(span, "round_robin:x", "x")

      assert result != nil
    end
  end

  # ===========================================================================
  # G35: DummySpan is not recording
  # ===========================================================================

  describe "G35: DummySpan / noop span behavior" do
    test "DummySpan.is_recording returns false" do
      span = DummySpan.new()
      assert DummySpan.is_recording(span) == false
    end

    test "DummySpan.set_attributes is a no-op" do
      span = DummySpan.new()

      result =
        DummySpan.set_attributes(span, %{"gen_ai.response.model" => "anything"})

      # Returns the same struct (no mutation, no crash)
      assert result == span
    end

    test "set_span_attributes with DummySpan does nothing" do
      span = DummySpan.new()

      result =
        set_span_attributes(
          span,
          "round_robin:model1",
          "model1"
        )

      # DummySpan.is_recording is false → no attributes set
      assert result == span
    end

    test "DummySpan is equivalent to Python's DummySpan fallback" do
      # Python's DummySpan:
      # class DummySpan:
      # def is_recording(self): return False
      # def set_attributes(self, attributes): pass
      #
      # Our Elixir DummySpan mirrors this exactly:
      # - is_recording/1 → false
      # - set_attributes/2 → identity (returns span unchanged)
      span = DummySpan.new()

      assert DummySpan.is_recording(span) == false
      assert DummySpan.set_attributes(span, %{}) == span
    end
  end
end
