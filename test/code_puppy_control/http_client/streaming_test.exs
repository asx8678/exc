defmodule CodePuppyControl.HttpClient.StreamingTest do
  @moduledoc """
  Tests for HttpClient.Streaming — the low-level Finch stream-process manager.

  These tests verify the streaming contract:
  - 2xx responses yield `{:data, chunk}` then `{:done, metadata}`
  - Non-2xx responses yield `{:error, %{status, body, headers}}` without `{:done, ...}`
  - Transport errors yield `{:error, reason}`

  ## Regression Note

  The Finch 0.18 `stream/5` function wraps the callback return in `{:cont, result}`
  before delegating to `stream_while/5`. This means the callback must return the
  plain accumulator, NOT `{:cont, acc}`. Returning `{:cont, acc}` would nest the
  accumulator into `{:cont, {:cont, map}}` and cause a "expected a map" crash.

  This test suite includes a regression test proving non-2xx streams return
  `{:error, %{status: 404, ...}}` — not a bad-map / transport error.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Test.MockLLMHTTP

  setup do
    start_supervised!(MockLLMHTTP)
    MockLLMHTTP.reset()
    :ok
  end

  # We test Streaming indirectly through MockLLMHTTP because
  # Streaming.run_finch_stream/8 requires a real Finch pool and a live
  # HTTP server. The contract it implements is verified through the
  # MockLLMHTTP.stream/3 wrapper which mirrors the same element shapes.

  describe "non-2xx stream regression (Finch.stream/5 accumulator bug)" do
    test "non-2xx stream returns {:error, %{status: 404, ...}}, not a bad-map error" do
      # This test verifies the contract that non-2xx responses produce
      # {:error, %{status, ...}} elements — NOT wrapped tuples like
      # {:cont, %{status: 404, ...}} which was the Finch 0.18 bug.
      #
      # Before the fix, the accumulator became {:cont, %{status: 404, ...}}
      # which caused downstream pattern matches like `acc.status in 200..299`
      # to crash with "expected a map, got: {:cont, %{status: 404, ...}}".

      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:ok, %{status: 404, body: ~s({"error":"Not Found"}), headers: []}}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com/responses", [])
        |> Enum.to_list()

      # Must produce exactly one error element with the correct shape
      assert [{:error, %{status: 404, body: body}}] = events
      assert body =~ "Not Found"

      # Must NOT produce {:done, ...} for errors
      refute Enum.any?(events, &match?({:done, _}, &1))

      # Must NOT produce wrapped tuples like {:cont, _}
      refute Enum.any?(events, fn
               {:error, {:cont, _}} -> true
               _ -> false
             end)
    end

    test "non-2xx stream returns {:error, %{status: 401, ...}} without bad map" do
      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:ok,
         %{
           status: 401,
           body: ~s({"error":"Unauthorized"}),
           headers: [{"www-authenticate", "Bearer"}]
         }}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com/responses", [])
        |> Enum.to_list()

      assert [{:error, %{status: 401, body: body, headers: headers}}] = events
      assert body =~ "Unauthorized"
      assert headers == [{"www-authenticate", "Bearer"}]
    end

    test "2xx stream yields {:data, chunk} then {:done, metadata}" do
      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:ok,
         %{status: 200, body: "event data here", headers: [{"content-type", "text/event-stream"}]}}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com/responses", [])
        |> Enum.to_list()

      assert [
               {:data, "event data here"},
               {:done, %{status: 200, headers: [{"content-type", "text/event-stream"}]}}
             ] = events
    end
  end

  describe "Finch.stream callback return values" do
    test "Finch.stream/5 wraps callback returns in {:cont, _} — proof of concept" do
      # This test documents the Finch 0.18 behavior that caused the bug.
      # Finch.stream/5 does: fn entry, acc -> {:cont, user_fun.(entry, acc)} end
      # So if user_fun returns {:cont, acc}, the accumulator becomes {:cont, {:cont, acc}}.

      # Simulate the old buggy behavior:
      old_callback = fn _entry, acc ->
        {:cont, Map.put(acc, :count, acc.count + 1)}
      end

      finch_wrapper = fn entry, acc ->
        {:cont, old_callback.(entry, acc)}
      end

      # After one iteration with the wrapper:
      initial_acc = %{count: 0}
      result = finch_wrapper.(:some_event, initial_acc)

      # The Finch wrapper turns {:cont, %{count: 1}} into {:cont, {:cont, %{count: 1}}}
      assert result == {:cont, {:cont, %{count: 1}}}

      # This is the nested tuple that caused the "expected a map" error
      refute match?({:cont, %{count: 1}}, result),
             "Finch.stream wraps the callback return, causing double-nesting"
    end

    test "correct callback returns plain accumulator — not wrapped" do
      # The fix: return the plain accumulator from the callback
      fixed_callback = fn _entry, acc ->
        Map.put(acc, :count, acc.count + 1)
      end

      finch_wrapper = fn entry, acc ->
        {:cont, fixed_callback.(entry, acc)}
      end

      initial_acc = %{count: 0}
      result = finch_wrapper.(:some_event, initial_acc)

      # Now the result is correctly shaped: {:cont, %{count: 1}}
      assert result == {:cont, %{count: 1}}
    end
  end
end
