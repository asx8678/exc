defmodule CodePuppyControl.Compaction.IntegrationTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Compaction
  alias CodePuppyControl.Compaction.{FileOpsTracker, ToolArgTruncation}
  alias CodePuppyControl.Messages.Pruner

  # Helper: build a realistic message history simulating a coding session
  defp build_realistic_history(opts \\ []) do
    num_turns = Keyword.get(opts, :turns, 20)

    # System message
    system = %{
      "kind" => "request",
      "parts" => [%{"part_kind" => "text", "content" => "You are a coding assistant."}]
    }

    # Build tool-call / tool-return pairs for file operations
    tool_pairs =
      for i <- 1..num_turns do
        file = "lib/module_#{rem(i, 5)}.ex"

        user_msg = %{
          "kind" => "request",
          "parts" => [%{"part_kind" => "text", "content" => "Update module #{i}"}]
        }

        tool_call = %{
          "kind" => "response",
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_call_id" => "tc-#{i}",
              "tool_name" => "replace_in_file",
              "args" => %{
                "file_path" => file,
                "old_string" => String.duplicate("old ", 20),
                "new_string" => String.duplicate("new ", 20)
              }
            }
          ]
        }

        tool_return = %{
          "kind" => "request",
          "parts" => [
            %{
              "part_kind" => "tool-return",
              "tool_call_id" => "tc-#{i}",
              "tool_name" => "replace_in_file",
              "content" => "Successfully replaced content in #{file}"
            }
          ]
        }

        assistant_response = %{
          "kind" => "response",
          "parts" => [%{"part_kind" => "text", "content" => "Updated #{file} successfully."}]
        }

        [user_msg, tool_call, tool_return, assistant_response]
      end
      |> List.flatten()

    [system | tool_pairs]
  end

  describe "full compaction pipeline" do
    test "handles realistic coding session history" do
      messages = build_realistic_history(turns: 20)
      # 1 system + 20*4 tool pairs
      assert length(messages) == 81

      {:ok, result, stats} = Compaction.compact(messages)

      # Should have applied some form of compaction
      assert stats.original_count == 81
      assert length(result) <= stats.original_count

      # Stats should be populated
      assert stats.filtered_count > 0
      assert stats.file_ops != nil
    end

    test "preserves system message (index 0) always" do
      messages = build_realistic_history(turns: 20)

      {:ok, result, _stats} = Compaction.compact(messages)

      # First message should always be the system message
      first = List.first(result)
      assert first["parts"] |> List.first() |> Map.get("content") =~ "coding assistant"
    end

    test "tool pair integrity is maintained after compaction" do
      messages = build_realistic_history(turns: 30)

      {:ok, result, _stats} = Compaction.compact(messages)

      # Verify: every tool-call in result has a matching tool-return, and vice versa
      call_ids =
        result
        |> Enum.flat_map(fn msg -> msg["parts"] || [] end)
        |> Enum.filter(fn p -> p["part_kind"] == "tool-call" end)
        |> Enum.map(fn p -> p["tool_call_id"] end)
        |> MapSet.new()

      return_ids =
        result
        |> Enum.flat_map(fn msg -> msg["parts"] || [] end)
        |> Enum.filter(fn p -> p["part_kind"] == "tool-return" end)
        |> Enum.map(fn p -> p["tool_call_id"] end)
        |> MapSet.new()

      # Every call should have a matching return
      assert MapSet.subset?(call_ids, return_ids)
      # Every return should have a matching call
      assert MapSet.subset?(return_ids, call_ids)
    end

    test "truncation reclaims tokens in old messages" do
      # Build messages with large tool args
      large_tool_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "tool_call_id" => "tc-big",
            "args" => %{
              "content" => String.duplicate("BIG_CONTENT ", 500),
              "file_path" => "big_file.ex"
            }
          }
        ]
      }

      large_return_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-return",
            "tool_call_id" => "tc-big",
            "content" => String.duplicate("BIG_RESULT ", 500)
          }
        ]
      }

      # 10 large old messages + 3 recent
      old_pairs = List.duplicate(large_tool_msg, 10) ++ List.duplicate(large_return_msg, 10)
      recent = List.duplicate(%{"parts" => [%{"part_kind" => "text", "content" => "recent"}]}, 3)
      messages = old_pairs ++ recent

      {:ok, _result, stats} = Compaction.compact(messages, keep_recent_for_truncation: 3)

      # Old messages should have been truncated
      assert stats.truncated_count > 0
    end

    test "compaction works with shadow mode enabled" do
      messages = build_realistic_history(turns: 10)

      {:ok, result, stats} =
        Compaction.compact(messages, shadow_mode: true)

      assert stats.original_count == 41
      assert length(result) > 0
    end
  end

  describe "pruning pipeline stages" do
    test "stage 1: filter drops mismatched pairs" do
      messages = [
        %{
          "kind" => "request",
          "parts" => [%{"part_kind" => "tool-call", "tool_call_id" => "orphan", "content" => "x"}]
        },
        %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "ok"}]}
      ]

      result = Pruner.prune_and_filter(messages)

      assert result.dropped_count == 1
      assert result.surviving_indices == [1]
    end

    test "stage 2: truncation reduces token usage" do
      messages = [
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "create_file",
              "args" => %{"content" => String.duplicate("x", 1000)}
            }
          ]
        }
      ]

      {truncated, count} = ToolArgTruncation.pretruncate_messages(messages, keep_recent: 0)

      assert count == 1
      first_part = List.first(truncated) |> Map.get("parts") |> List.first()
      assert String.length(first_part["args"]["content"]) < 1000
    end

    test "stage 3: split identifies summarize vs protected" do
      per_message_tokens = [100, 200, 300, 400, 500]

      messages =
        Enum.map(1..5, fn i ->
          %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "msg #{i}"}]}
        end)

      result = Pruner.split_for_summarization(per_message_tokens, messages, 700)

      assert 0 in result.protected_indices
      assert result.summarize_indices != []
    end
  end

  describe "file ops tracking through compaction" do
    test "extracts file ops from realistic history" do
      messages = build_realistic_history(turns: 10)

      tracker = FileOpsTracker.extract_from_messages(messages)

      assert FileOpsTracker.has_ops?(tracker)
      assert FileOpsTracker.modified_files(tracker) != []
    end

    test "file ops appear in compaction stats" do
      messages = build_realistic_history(turns: 5)

      {:ok, _result, stats} = Compaction.compact(messages)

      assert stats.file_ops != nil
      assert FileOpsTracker.has_ops?(stats.file_ops)
    end
  end

  describe "edge cases" do
    test "handles single message" do
      messages = [%{"parts" => [%{"part_kind" => "text", "content" => "only"}]}]

      {:ok, result, stats} = Compaction.compact(messages)

      assert length(result) == 1
      assert stats.original_count == 1
    end

    test "handles all-tool-call history" do
      messages =
        for i <- 1..20 do
          %{
            "parts" => [
              %{
                "part_kind" => "tool-call",
                "tool_call_id" => "tc-#{i}",
                "tool_name" => "read_file",
                "args" => %{"file_path" => "file_#{i}.ex"}
              }
            ]
          }
        end

      # Without matching returns, these should all be dropped by filter
      {:ok, result, stats} = Compaction.compact(messages)

      assert stats.dropped_by_filter > 0
    end

    test "no truncation when pretruncate is disabled" do
      messages = [
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "create_file",
              "args" => %{"content" => String.duplicate("x", 600)}
            }
          ]
        }
      ]

      {:ok, _result, stats} = Compaction.compact(messages, pretruncate: false)

      assert stats.truncated_count == 0
    end

    test "small messages stay below min_keep threshold" do
      messages =
        for i <- 1..5 do
          %{"kind" => "request", "parts" => [%{"part_kind" => "text", "content" => "msg #{i}"}]}
        end

      {:ok, result, stats} = Compaction.compact(messages, min_keep: 10)

      # All 5 messages should be kept (below min_keep)
      assert length(result) == 5
      assert stats.summarize_count == 0
    end
  end
end
