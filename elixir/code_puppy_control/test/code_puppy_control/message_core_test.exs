defmodule CodePuppyControl.MessageCoreTest do
  @moduledoc """
  Smoke and delegation tests for the MessageCore namespace.

  These tests verify that:
    1. All MessageCore modules compile and are accessible
    2. Delegation to existing implementations works correctly
    3. The new namespace returns the same results as the old namespace

  This ensures backward compatibility while allowing migration to the new namespace.
  """

  use ExUnit.Case

  alias CodePuppyControl.MessageCore.{
    Hasher,
    TokenEstimator,
    Serializer,
    Pruner,
    MessageBatch
  }

  # Keep old namespace aliases to verify compatibility
  alias CodePuppyControl.Messages.Hasher, as: OldHasher
  alias CodePuppyControl.Tokens.Estimator, as: OldEstimator
  alias CodePuppyControl.Messages.Serializer, as: OldSerializer
  alias CodePuppyControl.Messages.Pruner, as: OldPruner

  # ============================================================================
  # Helper functions
  # ============================================================================

  defp sample_message do
    %{
      kind: "request",
      role: "user",
      instructions: nil,
      parts: [
        %{
          part_kind: "text",
          content: "Hello, world!",
          content_json: nil,
          tool_call_id: nil,
          tool_name: nil,
          args: nil
        }
      ]
    }
  end

  defp sample_message_with_tools do
    %{
      kind: "request",
      role: "assistant",
      instructions: "You are helpful",
      parts: [
        %{
          part_kind: "text",
          content: "I'll search for that",
          content_json: nil,
          tool_call_id: nil,
          tool_name: nil,
          args: nil
        },
        %{
          part_kind: "tool-call",
          content: nil,
          content_json: ~s({"query": "elixir testing"}),
          tool_call_id: "call_123",
          tool_name: "search",
          args: nil
        },
        %{
          part_kind: "tool-return",
          content: "Elixir testing results",
          content_json: nil,
          tool_call_id: "call_123",
          tool_name: nil,
          args: nil
        }
      ]
    }
  end

  defp sample_part do
    %{
      part_kind: "text",
      content: "def hello, do: :world",
      content_json: nil,
      tool_call_id: nil,
      tool_name: nil,
      args: nil
    }
  end

  # ============================================================================
  # Namespace Structure Smoke Tests
  # ============================================================================

  describe "namespace structure" do
    test "root module loads" do
      assert CodePuppyControl.MessageCore.module_info(:module) == CodePuppyControl.MessageCore
    end

    test "all submodules are accessible and delegate correctly" do
      msg = sample_message()

      # Hasher delegation smoke test
      assert is_integer(Hasher.hash_message(msg))
      assert Hasher.hash_message(msg) == OldHasher.hash_message(msg)

      # TokenEstimator delegation smoke test
      assert is_integer(TokenEstimator.estimate_tokens("hello"))
      assert TokenEstimator.estimate_tokens("hello") == OldEstimator.estimate_tokens("hello")

      # Serializer delegation smoke test
      {:ok, binary} = Serializer.serialize_session([msg])
      assert is_binary(binary)
      {:ok, old_binary} = OldSerializer.serialize_session([msg])
      assert binary == old_binary

      # Pruner delegation smoke test
      assert is_map(Pruner.prune_and_filter([], 50000))
      assert Pruner.prune_and_filter([], 50000) == OldPruner.prune_and_filter([], 50000)

      # MessageBatch placeholder namespace only
      assert is_atom(MessageBatch)
    end
  end

  # ============================================================================
  # Hasher Delegation Tests
  # ============================================================================

  describe "Hasher delegation" do
    test "stringify_part_for_hash/1 delegates correctly" do
      part = sample_part()

      assert Hasher.stringify_part_for_hash(part) == OldHasher.stringify_part_for_hash(part)
      assert is_binary(Hasher.stringify_part_for_hash(part))
    end
  end

  # ============================================================================
  # Pruner Delegation Tests
  # ============================================================================

  describe "Pruner delegation" do
    test "truncation_indices/3 delegates correctly" do
      tokens = [100, 200, 300, 400]
      protected = 150

      result = Pruner.truncation_indices(tokens, protected, false)
      old_result = OldPruner.truncation_indices(tokens, protected, false)

      assert result == old_result
      assert is_list(result)
    end

    test "truncation_indices/3 with thinking flag delegates correctly" do
      tokens = [100, 200, 300, 400]
      protected = 150

      result = Pruner.truncation_indices(tokens, protected, true)
      old_result = OldPruner.truncation_indices(tokens, protected, true)

      assert result == old_result
    end

    test "split_for_summarization/3 delegates correctly" do
      tokens = [100, 50, 200, 75, 300]
      messages = Enum.map(1..5, fn i -> sample_message() |> Map.put(:id, i) end)
      protected_limit = 500

      result = Pruner.split_for_summarization(tokens, messages, protected_limit)
      old_result = OldPruner.split_for_summarization(tokens, messages, protected_limit)

      assert result == old_result
      assert is_map(result)
      assert Map.has_key?(result, :summarize_indices)
      assert Map.has_key?(result, :protected_indices)
    end
  end

  # ============================================================================
  # Serializer Delegation Tests
  # ============================================================================

  describe "Serializer delegation" do
    test "serialize_session_incremental/2 delegates correctly" do
      messages = [sample_message()]

      # Fresh serialization
      {:ok, result} = Serializer.serialize_session_incremental(messages, nil)
      {:ok, old_result} = OldSerializer.serialize_session_incremental(messages, nil)

      assert result == old_result
      assert is_binary(result)

      # Incremental append
      more_messages = [sample_message_with_tools()]
      {:ok, appended} = Serializer.serialize_session_incremental(more_messages, result)
      {:ok, old_appended} = OldSerializer.serialize_session_incremental(more_messages, old_result)

      assert appended == old_appended
    end
  end

  # ============================================================================
  # TokenEstimator Delegation Tests
  # ============================================================================

  describe "TokenEstimator delegation" do
    test "chars_per_token/1 delegates correctly" do
      text = "defmodule Foo do\n  def bar, do: :baz\nend"

      result = TokenEstimator.chars_per_token(text)
      old_result = OldEstimator.chars_per_token(text)

      assert result == old_result
      assert is_float(result) or is_integer(result)
    end

    test "is_code_heavy/1 delegates correctly" do
      code = "defmodule Foo do\n  def bar, do: :baz\nend"
      prose = "This is a simple sentence about Elixir programming."

      assert TokenEstimator.is_code_heavy(code) == OldEstimator.is_code_heavy(code)
      assert TokenEstimator.is_code_heavy(prose) == OldEstimator.is_code_heavy(prose)
      assert is_boolean(TokenEstimator.is_code_heavy(code))
    end

    test "stringify_part_for_tokens/1 delegates correctly" do
      part = sample_part()

      result = TokenEstimator.stringify_part_for_tokens(part)
      old_result = OldEstimator.stringify_part_for_tokens(part)

      assert result == old_result
      assert is_binary(result)
    end

    test "estimate_context_overhead/3 delegates correctly" do
      tool_defs = [%{name: "test_tool", description: "A test tool"}]
      mcp_defs = []
      system = "You are a helpful assistant."

      result = TokenEstimator.estimate_context_overhead(tool_defs, mcp_defs, system)
      old_result = OldEstimator.estimate_context_overhead(tool_defs, mcp_defs, system)

      assert result == old_result
      assert is_integer(result)
    end

    test "ensure_table_exists/0 delegates correctly" do
      # Just verify it doesn't raise and returns :ok
      assert TokenEstimator.ensure_table_exists() == OldEstimator.ensure_table_exists()
    end
  end

  # ============================================================================
  # End-to-End Delegation Smoke Test
  # ============================================================================

  test "full pipeline with new namespace delegates correctly" do
    messages = [sample_message(), sample_message_with_tools()]

    # Hash - verify delegation to old namespace
    new_hashes = Enum.map(messages, &Hasher.hash_message/1)
    old_hashes = Enum.map(messages, &OldHasher.hash_message/1)
    assert new_hashes == old_hashes

    # Token estimation - verify delegation
    assert TokenEstimator.estimate_message_tokens(sample_message()) ==
             OldEstimator.estimate_message_tokens(sample_message())

    # Batch processing - verify delegation
    new_batch = TokenEstimator.process_messages_batch(messages, [], [], "Test prompt")
    old_batch = OldEstimator.process_messages_batch(messages, [], [], "Test prompt")
    assert new_batch == old_batch

    # Serialization - verify round-trip and delegation
    {:ok, binary} = Serializer.serialize_session(messages)
    {:ok, old_binary} = OldSerializer.serialize_session(messages)
    assert binary == old_binary

    {:ok, decoded} = Serializer.deserialize_session(binary)
    {:ok, old_decoded} = OldSerializer.deserialize_session(binary)
    assert decoded == old_decoded
  end
end
