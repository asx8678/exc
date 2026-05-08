defmodule CodePuppyControl.Compaction.FacadeTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Compaction

  describe "should_compact?/2" do
    test "returns false for small message lists" do
      messages = List.duplicate(%{"parts" => []}, 50)
      assert Compaction.should_compact?(messages) == false
    end

    test "returns true when over threshold" do
      messages = List.duplicate(%{"parts" => []}, 150)
      assert Compaction.should_compact?(messages) == true
    end

    test "respects custom trigger_messages option" do
      messages = List.duplicate(%{"parts" => []}, 50)
      assert Compaction.should_compact?(messages, trigger_messages: 100) == false
      assert Compaction.should_compact?(messages, trigger_messages: 50) == true
    end
  end

  describe "compact/2" do
    test "filters mismatched tool pairs" do
      messages = [
        %{
          "kind" => "request",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "orphan", "content" => "call"}
          ]
        },
        %{
          "kind" => "request",
          "parts" => [
            %{"part_kind" => "text", "content" => "hello"}
          ]
        }
      ]

      {:ok, result, stats} = Compaction.compact(messages)

      # Orphan tool call should be dropped
      assert stats.dropped_by_filter == 1

      assert Enum.any?(result, fn msg ->
               parts = msg["parts"] || []
               Enum.any?(parts, fn p -> p["tool_call_id"] == "orphan" end)
             end) == false
    end

    test "truncates old tool args" do
      old_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "tool_call_id" => "tc-1",
            "args" => %{"content" => String.duplicate("x", 600), "file_path" => "a.ex"}
          }
        ]
      }

      return_msg = %{
        "parts" => [
          %{
            "part_kind" => "tool-return",
            "tool_call_id" => "tc-1",
            "content" => "ok"
          }
        ]
      }

      # Build messages: old tool pair + padding + recent
      padding =
        List.duplicate(
          %{"parts" => [%{"part_kind" => "text", "content" => "padding"}]},
          30
        )

      recent = %{"parts" => [%{"part_kind" => "text", "content" => "recent"}]}
      messages = [old_msg, return_msg] ++ padding ++ [recent]

      {:ok, _result, stats} = Compaction.compact(messages, keep_recent_for_truncation: 1)

      assert stats.truncated_count >= 1
    end

    test "handles empty messages" do
      {:ok, result, stats} = Compaction.compact([])

      assert result == []
      assert stats.original_count == 0
      assert stats.filtered_count == 0
    end

    test "splits for summarization with sufficient messages" do
      # Build 200 messages with substantial content so tokens accumulate
      messages =
        for i <- 1..200 do
          %{
            "kind" => "request",
            "parts" => [
              %{
                "part_kind" => "text",
                "content" =>
                  "This is message number #{i}. It contains some text to ensure reasonable token counts for the compaction algorithm. The split_for_summarization function needs enough tokens to trigger the summarization threshold."
              }
            ]
          }
        end

      {:ok, result, stats} = Compaction.compact(messages, min_keep: 2)

      # Should have reduced message count via splitting
      assert stats.summarize_count > 0
      assert stats.protected_count > 0
      assert length(result) == stats.protected_count
    end

    test "preserves message order" do
      messages =
        for i <- 1..50 do
          %{
            "kind" => "request",
            "parts" => [%{"part_kind" => "text", "content" => "msg #{i}"}]
          }
        end

      {:ok, result, _stats} = Compaction.compact(messages, min_keep: 10)

      # Protected messages should maintain original order
      contents =
        Enum.map(result, fn msg ->
          msg["parts"] |> List.first() |> Map.get("content")
        end)

      # Verify order is preserved by checking indices increase monotonically
      indices =
        Enum.map(contents, fn c ->
          c |> String.replace_prefix("msg ", "") |> String.to_integer()
        end)

      assert indices == Enum.sort(indices)
    end

    test "returns file_ops tracker in stats" do
      messages = [
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "read_file",
              "args" => %{"file_path" => "lib/test.ex"}
            }
          ]
        }
      ]

      {:ok, _result, stats} = Compaction.compact(messages)

      assert stats.file_ops != nil
    end

    test "respects keep_recent_for_truncation option" do
      tool_msg = fn i ->
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "create_file",
              "tool_call_id" => "tc-#{i}",
              "args" => %{"content" => String.duplicate("x", 600), "file_path" => "file_#{i}.ex"}
            }
          ]
        }
      end

      tool_return = fn i ->
        %{
          "parts" => [
            %{
              "part_kind" => "tool-return",
              "tool_call_id" => "tc-#{i}",
              "content" => "ok"
            }
          ]
        }
      end

      # Build 15 tool-call + tool-return pairs + 5 recent
      tool_pairs =
        Enum.flat_map(1..15, fn i -> [tool_msg.(i), tool_return.(i)] end)

      recent = List.duplicate(%{"parts" => [%{"part_kind" => "text", "content" => "r"}]}, 5)

      messages = tool_pairs ++ recent

      {:ok, _result, stats} = Compaction.compact(messages, keep_recent_for_truncation: 5)

      # Should truncate the 15 old tool-call messages
      assert stats.truncated_count > 0
    end
  end

  describe "file_ops_summary/1" do
    test "formats tracker as XML" do
      alias CodePuppyControl.Compaction.FileOpsTracker

      tracker =
        FileOpsTracker.new()
        |> FileOpsTracker.track_tool_call("read_file", %{"file_path" => "lib/a.ex"})
        |> FileOpsTracker.track_tool_call("create_file", %{"file_path" => "lib/b.ex"})

      summary = Compaction.file_ops_summary(tracker)

      assert summary =~ "<read-files>"
      assert summary =~ "lib/a.ex"
      assert summary =~ "<modified-files>"
      assert summary =~ "lib/b.ex"
    end
  end
end
