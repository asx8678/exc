defmodule CodePuppyControl.Stream.NormalizerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.Normalizer
  alias CodePuppyControl.Stream.Event

  describe "normalize/1 - provider events" do
    test "wraps text part_delta in {:stream, TextDelta}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)

          normalized.(
            {:part_delta, %{type: :text, index: 0, text: "Hello", name: nil, arguments: nil}}
          )
        end)

      assert [{:stream, %Event.TextDelta{index: 0, text: "Hello"}}] = events
    end

    test "wraps text part_start in {:stream, TextStart}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.({:part_start, %{type: :text, index: 0, id: nil}})
        end)

      assert [{:stream, %Event.TextStart{index: 0, id: nil}}] = events
    end

    test "wraps text part_end in {:stream, TextEnd}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)

          normalized.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})
        end)

      assert [{:stream, %Event.TextEnd{index: 0, id: nil}}] = events
    end

    test "wraps tool_call part_start in {:stream, ToolCallStart}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.({:part_start, %{type: :tool_call, index: 0, id: "tc-1"}})
        end)

      assert [{:stream, %Event.ToolCallStart{index: 0, id: "tc-1", name: nil}}] = events
    end

    test "wraps tool_call name delta in {:stream, ToolCallStart}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)

          normalized.(
            {:part_delta, %{type: :tool_call, index: 0, text: nil, name: "exec", arguments: nil}}
          )
        end)

      assert [{:stream, %Event.ToolCallStart{index: 0, id: nil, name: "exec"}}] = events
    end

    test "wraps tool_call args delta in {:stream, ToolCallArgsDelta}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)

          normalized.(
            {:part_delta,
             %{type: :tool_call, index: 0, text: nil, name: nil, arguments: "{\"k\":"}}
          )
        end)

      assert [{:stream, %Event.ToolCallArgsDelta{index: 0, arguments: "{\"k\":"}}] = events
    end

    test "wraps tool_call part_end in {:stream, ToolCallEnd}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)

          normalized.(
            {:part_end, %{type: :tool_call, index: 0, id: "tc-1", name: "exec", arguments: "{}"}}
          )
        end)

      assert [
               {:stream,
                %Event.ToolCallEnd{
                  index: 0,
                  id: "tc-1",
                  name: "exec",
                  arguments: "{}"
                }}
             ] = events
    end

    test "wraps done event in {:stream, Done}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)

          normalized.(
            {:done,
             %{
               id: "msg-1",
               model: "gpt-4o",
               finish_reason: "stop",
               usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
             }}
          )
        end)

      assert [{:stream, %Event.Done{id: "msg-1", model: "gpt-4o"}}] = events
    end
  end

  describe "normalize/1 - legacy events" do
    test "converts {:text, chunk} to {:stream, TextDelta}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.({:text, "Hello world"})
        end)

      assert [{:stream, %Event.TextDelta{index: 0, text: "Hello world"}}] = events
    end

    test "converts {:tool_call, name, args, id} to {:stream, ToolCallEnd}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.({:tool_call, "exec", %{"cmd" => "ls"}, "tc-1"})
        end)

      assert [
               {:stream,
                %Event.ToolCallEnd{
                  index: 0,
                  id: "tc-1",
                  name: "exec",
                  arguments: args_json
                }}
             ] = events

      assert Jason.decode!(args_json) == %{"cmd" => "ls"}
    end

    test "converts {:done, reason} to {:stream, Done}" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.({:done, :complete})
        end)

      assert [{:stream, %Event.Done{}}] = events
    end
  end

  describe "normalize/1 - pass-through" do
    test "passes through unrecognized events unchanged" do
      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.({:error, "something went wrong"})
          normalized.(:some_atom)
        end)

      assert events == [{:error, "something went wrong"}, :some_atom]
    end
  end

  describe "convert/1" do
    test "converts provider event directly" do
      assert {:ok, %Event.TextDelta{index: 0, text: "Hi"}} =
               Normalizer.convert(
                 {:part_delta, %{type: :text, index: 0, text: "Hi", name: nil, arguments: nil}}
               )
    end

    test "converts legacy event directly" do
      assert {:ok, %Event.TextDelta{index: 0, text: "Hi"}} =
               Normalizer.convert({:text, "Hi"})
    end

    test "returns :skip for unrecognizable events" do
      assert :skip = Normalizer.convert(:random)
    end
  end

  describe "normalize/1 - contract" do
    test "raises FunctionClauseError when given a non-function" do
      assert_raise FunctionClauseError, fn ->
        Normalizer.normalize("not a function")
      end

      assert_raise FunctionClauseError, fn ->
        Normalizer.normalize(:atom)
      end

      assert_raise FunctionClauseError, fn ->
        Normalizer.normalize(123)
      end
    end

    test "raises FunctionClauseError when given a function of wrong arity" do
      # Function with arity 2 instead of required arity 1
      assert_raise FunctionClauseError, fn ->
        Normalizer.normalize(fn _arg1, _arg2 -> :ok end)
      end

      # Function with arity 0 instead of required arity 1
      assert_raise FunctionClauseError, fn ->
        Normalizer.normalize(fn -> :ok end)
      end
    end

    test "passes through already-wrapped {:stream, event} tuples unchanged" do
      # Create an already-wrapped event tuple
      wrapped = {:stream, %Event.TextDelta{index: 0, text: "already wrapped"}}

      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          # This should pass through unchanged (identity on wrapped events)
          normalized.(wrapped)
        end)

      # Should receive the wrapped tuple unchanged
      assert [^wrapped] = events
    end

    test "passes through wrapped ToolCallEnd unchanged" do
      wrapped =
        {:stream,
         %Event.ToolCallEnd{
           index: 1,
           id: "tc-2",
           name: "test_tool",
           arguments: "{}"
         }}

      events =
        collect_normalized(fn callback ->
          normalized = Normalizer.normalize(callback)
          normalized.(wrapped)
        end)

      assert [^wrapped] = events
    end
  end

  # Helper to collect events from a callback
  defp collect_normalized(build_fn) do
    test_pid = self()

    callback = fn event ->
      send(test_pid, {:event, event})
    end

    build_fn.(callback)

    collect_events([])
  end

  defp collect_events(acc) do
    receive do
      {:event, event} -> collect_events([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
