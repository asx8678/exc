defmodule CodePuppyControl.Tokens.EstimatorTest do
  use ExUnit.Case
  alias CodePuppyControl.Tokens.Estimator
  alias CodePuppyControl.Messages.Hasher

  describe "estimate_tokens/1" do
    test "empty text returns 1" do
      assert Estimator.estimate_tokens("") == 1
    end

    test "short prose text" do
      # "Hello, world!" has 13 chars, prose uses 4.0 chars/token
      # 13 / 4.0 = 3.25 -> floor -> 3
      assert Estimator.estimate_tokens("Hello, world!") == 3
    end

    test "code detection affects ratio" do
      # Code with braces uses 4.5 chars/token
      code = "fn main() { println!(\"Hello\"); }"
      # 32 chars / 4.5 = 7.11 -> floor -> 7
      assert Estimator.estimate_tokens(code) == 7
    end

    test "short prose without code indicators" do
      # Short text without code indicators, 4.0 chars/token
      text = "This is a simple sentence for testing."
      # 38 chars / 4.0 = 9.5 -> floor -> 9
      assert Estimator.estimate_tokens(text) == 9
    end

    test "sampling path for large prose text" do
      # Large prose text without code indicators uses sampling
      # ~3500 chars of prose
      text = String.duplicate("word ", 700)
      # No code indicators, so ratio = 4.0
      # Should use sampling path and give approximately 3500/4.0 = 875
      result = Estimator.estimate_tokens(text)
      assert result > 800 and result < 950
    end

    test "sampling path for large code text" do
      # Large code text with code indicators uses 4.5 ratio
      code_line = "fn foo() { bar(); }\n"
      # ~2000 chars of code
      text = String.duplicate(code_line, 100)
      # Has code indicators, so ratio = 4.5
      # Should use sampling path and give approximately 2000/4.5 = 444
      result = Estimator.estimate_tokens(text)
      assert result > 400 and result < 500
    end

    test "caching returns same value for same text" do
      text = "This is test text for caching."
      result1 = Estimator.estimate_tokens(text)
      result2 = Estimator.estimate_tokens(text)
      assert result1 == result2
    end
  end

  describe "is_code_heavy/1" do
    test "python code detected" do
      python_code = "def hello():\n    return 'world'\n"
      assert Estimator.is_code_heavy(python_code)
    end

    test "prose not detected as code" do
      prose = "This is just regular text without any code."
      refute Estimator.is_code_heavy(prose)
    end

    test "mixed content with enough code indicators detected" do
      # 4 lines of code out of 5 total = 80% code lines
      mixed = "def a():\n    pass\ndef b():\n    pass\nSome text.\n"
      assert Estimator.is_code_heavy(mixed)
    end

    test "short text not detected as code" do
      short = "if x"
      refute Estimator.is_code_heavy(short)
    end

    test "javascript code detected" do
      js = "function test() { return 42; }"
      assert Estimator.is_code_heavy(js)
    end

    test "typescript arrow function detected" do
      ts = "const x = () => { return 1; }"
      assert Estimator.is_code_heavy(ts)
    end
  end

  describe "line_has_code_indicators?/1" do
    test "detects python if statement" do
      assert Estimator.line_has_code_indicators?("if x > 0:")
    end

    test "detects python def" do
      assert Estimator.line_has_code_indicators?("def foo():")
    end

    test "detects braces" do
      assert Estimator.line_has_code_indicators?("{\"key\": \"value\"}")
    end

    test "detects javascript function" do
      assert Estimator.line_has_code_indicators?("function test() {}")
    end

    test "detects C include" do
      assert Estimator.line_has_code_indicators?("#include <stdio.h>")
    end

    test "plain text not detected" do
      refute Estimator.line_has_code_indicators?("This is just text.")
    end

    test "hello world not detected" do
      refute Estimator.line_has_code_indicators?("Hello world")
    end

    test "detects brackets" do
      assert Estimator.line_has_code_indicators?("arr[0] = 1")
    end

    test "detects parentheses" do
      assert Estimator.line_has_code_indicators?("call()")
    end

    test "detects semicolon" do
      assert Estimator.line_has_code_indicators?("x = 1;")
    end
  end

  describe "stringify_part_for_tokens/1" do
    test "stringifies text part with content" do
      part = %{
        part_kind: "text",
        content: "Hello world",
        content_json: nil,
        tool_call_id: nil,
        tool_name: nil,
        args: nil
      }

      assert Estimator.stringify_part_for_tokens(part) == "Hello world"
    end

    test "stringifies part with content_json" do
      part = %{
        part_kind: "text",
        content: nil,
        content_json: "{\"key\": \"value\"}",
        tool_call_id: nil,
        tool_name: nil,
        args: nil
      }

      assert Estimator.stringify_part_for_tokens(part) == "{\"key\": \"value\"}"
    end

    test "stringifies tool call part" do
      part = %{
        part_kind: "tool_call",
        content: nil,
        content_json: nil,
        tool_call_id: "call_123",
        tool_name: "my_tool",
        args: "{\"arg\": 1}"
      }

      result = Estimator.stringify_part_for_tokens(part)
      assert result == "tool_call: my_tool {\"arg\": 1}"
    end
  end

  describe "process_messages_batch/4" do
    test "processes empty message list" do
      result = Estimator.process_messages_batch([], [], [], "")

      assert result.per_message_tokens == []
      assert result.total_tokens == 0
      assert result.context_overhead == 0
      assert result.message_hashes == []
    end

    test "processes single message" do
      msg = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "Hello",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      result = Estimator.process_messages_batch([msg], [], [], "")

      assert length(result.per_message_tokens) == 1
      assert result.total_tokens > 0
      assert result.context_overhead == 0
      assert length(result.message_hashes) == 1
    end

    test "processes multiple messages" do
      msgs = [
        %{
          kind: "request",
          role: "user",
          instructions: nil,
          parts: [
            %{
              part_kind: "text",
              content: "Hello",
              content_json: nil,
              tool_call_id: nil,
              tool_name: nil,
              args: nil
            }
          ]
        },
        %{
          kind: "response",
          role: "assistant",
          instructions: nil,
          parts: [
            %{
              part_kind: "text",
              content: "World",
              content_json: nil,
              tool_call_id: nil,
              tool_name: nil,
              args: nil
            }
          ]
        }
      ]

      result = Estimator.process_messages_batch(msgs, [], [], "")

      assert length(result.per_message_tokens) == 2
      assert result.total_tokens == Enum.sum(result.per_message_tokens)
      assert length(result.message_hashes) == 2
    end

    test "includes system prompt in context overhead" do
      result = Estimator.process_messages_batch([], [], [], "System prompt here.")

      assert result.context_overhead > 0
      assert result.context_overhead == Estimator.estimate_tokens("System prompt here.")
    end

    test "includes tool definitions in context overhead" do
      tool_defs = [
        %{name: "tool1", description: "First tool", input_schema: %{type: "object"}},
        %{name: "tool2", description: "Second tool", input_schema: %{type: "object"}}
      ]

      result = Estimator.process_messages_batch([], tool_defs, [], "")

      expected =
        Estimator.estimate_tokens("tool1") +
          Estimator.estimate_tokens("First tool") +
          Estimator.estimate_tokens("{\"type\":\"object\"}") +
          Estimator.estimate_tokens("tool2") +
          Estimator.estimate_tokens("Second tool") +
          Estimator.estimate_tokens("{\"type\":\"object\"}")

      assert result.context_overhead == expected
    end

    test "includes mcp tool definitions in context overhead" do
      mcp_defs = [
        %{name: "mcp_tool", description: "MCP tool", input_schema: nil}
      ]

      result = Estimator.process_messages_batch([], [], mcp_defs, "")

      assert result.context_overhead > 0
    end
  end

  describe "estimate_message_tokens/1" do
    test "empty message has minimum 1 token" do
      msg = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: []
      }

      assert Estimator.estimate_message_tokens(msg) == 1
    end

    test "message with parts returns token count" do
      msg = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "Hello",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          },
          %{
            part_kind: "text",
            content: "World",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      tokens = Estimator.estimate_message_tokens(msg)
      assert tokens > 1

      expected =
        Estimator.estimate_tokens("Hello") +
          Estimator.estimate_tokens("World")

      assert tokens == expected
    end
  end

  describe "estimate_context_overhead/3" do
    test "empty inputs return 0" do
      assert Estimator.estimate_context_overhead([], [], "") == 0
    end

    test "system prompt counted" do
      overhead = Estimator.estimate_context_overhead([], [], "Hello")
      assert overhead == Estimator.estimate_tokens("Hello")
    end

    test "tools with schemas counted" do
      tools = [
        %{name: "test", description: "desc", input_schema: %{type: "object", properties: %{}}}
      ]

      overhead = Estimator.estimate_context_overhead(tools, [], "")
      assert overhead > Estimator.estimate_tokens("test")
    end
  end

  describe "chars_per_token/1" do
    test "prose uses 4.0" do
      assert Estimator.chars_per_token("Hello world this is prose.") == 4.0
    end

    test "code uses 4.5" do
      assert Estimator.chars_per_token("def hello():\n    return 'world'") == 4.5
    end
  end

  describe "Hasher integration" do
    test "message hash is stable" do
      msg = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "Hello",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      hash1 = Hasher.hash_message(msg)
      hash2 = Hasher.hash_message(msg)
      assert hash1 == hash2
    end

    test "different messages have different hashes" do
      msg1 = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "Hello",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      msg2 = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [
          %{
            part_kind: "text",
            content: "World",
            content_json: nil,
            tool_call_id: nil,
            tool_name: nil,
            args: nil
          }
        ]
      }

      assert Hasher.hash_message(msg1) != Hasher.hash_message(msg2)
    end
  end
end
