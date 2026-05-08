defmodule CodePuppyControl.Stream.EventNormalizerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.EventNormalizer

  describe "normalize/2 — part_start events" do
    test "normalizes TextPart start" do
      result =
        EventNormalizer.normalize("part_start", %{
          "index" => 0,
          "part_type" => "TextPart",
          "content" => "Hello"
        })

      assert result.part_kind == "text"
      assert result.index == 0
      assert result.content_delta == "Hello"
      assert result.args_delta == nil
      assert result.tool_name == nil
      assert result.tool_name_delta == nil
    end

    test "normalizes ThinkingPart start" do
      result =
        EventNormalizer.normalize("part_start", %{
          "index" => 1,
          "part_type" => "ThinkingPart",
          "content" => "Hmm..."
        })

      assert result.part_kind == "thinking"
      assert result.content_delta == "Hmm..."
    end

    test "normalizes ToolCallPart start with tool_name" do
      result =
        EventNormalizer.normalize("part_start", %{
          "index" => 2,
          "part_type" => "ToolCallPart",
          "tool_name" => "read_file"
        })

      assert result.part_kind == "tool_call"
      assert result.tool_name == "read_file"
    end

    test "defaults to unknown for unrecognized part_type" do
      result =
        EventNormalizer.normalize("part_start", %{
          "index" => 3,
          "part_type" => "WeirdPart"
        })

      assert result.part_kind == "unknown"
    end

    test "defaults index to -1 when missing" do
      result =
        EventNormalizer.normalize("part_start", %{
          "part_type" => "TextPart"
        })

      assert result.index == -1
    end
  end

  describe "normalize/2 — part_delta events" do
    test "normalizes sub-agent format with content_delta" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 0,
          "delta_type" => "TextPartDelta",
          "content_delta" => " world"
        })

      assert result.part_kind == "text"
      assert result.content_delta == " world"
    end

    test "normalizes sub-agent format with args_delta" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 1,
          "delta_type" => "ToolCallPartDelta",
          "args_delta" => "{\"path\": \"/tmp\"}",
          "tool_name_delta" => "read"
        })

      assert result.part_kind == "tool_call"
      assert result.args_delta == "{\"path\": \"/tmp\"}"
      assert result.tool_name_delta == "read"
    end

    test "normalizes main-agent format with delta object (map)" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 0,
          "delta_type" => "TextPartDelta",
          "delta" => %{"content_delta" => " from delta"}
        })

      assert result.part_kind == "text"
      assert result.content_delta == " from delta"
    end

    test "normalizes ThinkingPartDelta" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 1,
          "delta_type" => "ThinkingPartDelta",
          "content_delta" => "thinking..."
        })

      assert result.part_kind == "thinking"
      assert result.content_delta == "thinking..."
    end

    test "extracts tool_name from event data" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 0,
          "delta_type" => "ToolCallPartDelta",
          "tool_name" => "write_file"
        })

      assert result.tool_name == "write_file"
    end

    test "extracts tool_name from delta object" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 0,
          "delta_type" => "ToolCallPartDelta",
          "delta" => %{"tool_name" => "grep"}
        })

      assert result.tool_name == "grep"
    end

    test "defaults to unknown for unrecognized delta_type" do
      result =
        EventNormalizer.normalize("part_delta", %{
          "index" => 0,
          "delta_type" => "WeirdDelta"
        })

      assert result.part_kind == "unknown"
    end
  end

  describe "normalize/2 — part_end events" do
    test "normalizes part_end with next_part_kind" do
      result =
        EventNormalizer.normalize("part_end", %{
          "index" => 0,
          "next_part_kind" => "text"
        })

      assert result.part_kind == "text"
    end

    test "normalizes part_end without next_part_kind" do
      result =
        EventNormalizer.normalize("part_end", %{
          "index" => 0
        })

      assert result.part_kind == "unknown"
    end

    test "normalizes part_end with tool_name" do
      result =
        EventNormalizer.normalize("part_end", %{
          "index" => 1,
          "tool_name" => "read_file"
        })

      assert result.tool_name == "read_file"
    end
  end

  describe "normalize/2 — unknown event types" do
    test "returns unknown part_kind for unrecognized event types" do
      result =
        EventNormalizer.normalize("custom_event", %{
          "index" => 0,
          "data" => "something"
        })

      assert result.part_kind == "unknown"
    end
  end

  describe "normalize/2 — non-map event data" do
    test "handles string fallback" do
      result = EventNormalizer.normalize("part_delta", "some text")

      assert result.content_delta == "some text"
      assert result.part_kind == "unknown"
      assert result.index == -1
    end

    test "handles nil fallback" do
      result = EventNormalizer.normalize("part_delta", nil)

      assert result.content_delta == nil
      assert result.part_kind == "unknown"
    end
  end

  describe "content_for_token_estimation/1" do
    test "extracts content_delta" do
      result =
        EventNormalizer.content_for_token_estimation(%{
          content_delta: "hello",
          args_delta: nil,
          tool_name_delta: nil
        })

      assert result == "hello"
    end

    test "concatenates content_delta and args_delta" do
      result =
        EventNormalizer.content_for_token_estimation(%{
          content_delta: "hi",
          args_delta: "{\"a\":1}",
          tool_name_delta: nil
        })

      assert result == "hi{\"a\":1}"
    end

    test "concatenates all three fields" do
      result =
        EventNormalizer.content_for_token_estimation(%{
          content_delta: "x",
          args_delta: "y",
          tool_name_delta: "z"
        })

      assert result == "xyz"
    end

    test "returns empty string when all nil" do
      result =
        EventNormalizer.content_for_token_estimation(%{
          content_delta: nil,
          args_delta: nil,
          tool_name_delta: nil
        })

      assert result == ""
    end
  end

  describe "part_kind helpers" do
    test "part_kind_from_start maps known types" do
      assert EventNormalizer.part_kind_from_start("TextPart") == "text"
      assert EventNormalizer.part_kind_from_start("ThinkingPart") == "thinking"
      assert EventNormalizer.part_kind_from_start("ToolCallPart") == "tool_call"
    end

    test "part_kind_from_start returns unknown for unknown types" do
      assert EventNormalizer.part_kind_from_start("OtherPart") == "unknown"
    end

    test "part_kind_from_delta maps known types" do
      assert EventNormalizer.part_kind_from_delta("TextPartDelta") == "text"
      assert EventNormalizer.part_kind_from_delta("ThinkingPartDelta") == "thinking"
      assert EventNormalizer.part_kind_from_delta("ToolCallPartDelta") == "tool_call"
    end

    test "part_kind_from_delta returns unknown for unknown types" do
      assert EventNormalizer.part_kind_from_delta("WeirdDelta") == "unknown"
    end

    test "part_kind_from_end returns the kind string" do
      assert EventNormalizer.part_kind_from_end("text") == "text"
      assert EventNormalizer.part_kind_from_end("tool_call") == "tool_call"
    end

    test "part_kind_from_end returns unknown for nil" do
      assert EventNormalizer.part_kind_from_end(nil) == "unknown"
    end
  end

  describe "raw field preservation" do
    test "raw field contains original event data" do
      original = %{"index" => 0, "part_type" => "TextPart", "extra" => "data"}
      result = EventNormalizer.normalize("part_start", original)

      assert result.raw["index"] == 0
      assert result.raw["part_type"] == "TextPart"
      assert result.raw["extra"] == "data"
    end
  end

  describe "atom-keyed event data" do
    test "handles atom-keyed maps" do
      result =
        EventNormalizer.normalize("part_start", %{
          index: 0,
          part_type: "TextPart",
          content: "hello"
        })

      assert result.part_kind == "text"
      assert result.index == 0
      assert result.content_delta == "hello"
    end
  end
end
