defmodule CodePuppyControl.Agent.LLMAdapterResponseTest do
  @moduledoc """
  Tests for LLMAdapter response reconstruction, error handling, and timeout.

  Covers:
  - response reconstruction: :ok return with buffered text + tool_calls
  - error pass-through from provider
  - adapter timeout when provider returns :ok silently
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.LLMAdapter
  alias CodePuppyControl.Test.LLMAdapterTestHelper.ProviderMock

  import CodePuppyControl.Test.LLMAdapterTestHelper, only: [setup_mock_provider: 0]

  setup do
    setup_mock_provider()
  end

  # ===========================================================================
  # 4. Response reconstruction: :ok return with buffered text + tool_calls
  # ===========================================================================

  describe "response reconstruction: :ok return with buffered text + tool_calls" do
    test "returns {:ok, %{text, tool_calls}} for text-only response" do
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_response(%{id: "r1", content: "Hello, human!", tool_calls: []})

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      assert resp.text == "Hello, human!"
      assert resp.tool_calls == []
    end

    test "extracts tool_calls from provider response" do
      msgs = [%{"role" => "user", "content" => "list files"}]
      tool_calls = [%{id: "tc1", name: "command_runner", arguments: %{"command" => "ls"}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      assert resp.text == ""
      assert length(resp.tool_calls) == 1

      [tc] = resp.tool_calls
      assert tc.id == "tc1"
      # safe_atomize converts known string tool names to atoms
      assert tc.name == :command_runner
      assert tc.arguments == %{"command" => "ls"}
    end

    test "handles multiple tool calls in response" do
      msgs = [%{"role" => "user", "content" => "multi-tool"}]

      tool_calls = [
        %{id: "tc1", name: "read_file", arguments: %{"path" => "a.ex"}},
        %{id: "tc2", name: "command_runner", arguments: %{"command" => "ls"}}
      ]

      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      assert length(resp.tool_calls) == 2
      # safe_atomize converts known string tool names to atoms
      assert Enum.map(resp.tool_calls, & &1.name) == [:read_file, :command_runner]
    end

    test "normalizes string-keyed tool calls to atom-keyed" do
      # Provider may return string-keyed tool calls
      msgs = [%{"role" => "user", "content" => "run"}]
      tool_calls = [%{"id" => "tc1", "name" => "read_file", "arguments" => %{"path" => "a.ex"}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      assert length(resp.tool_calls) == 1

      [tc] = resp.tool_calls
      # Adapter normalizes to atom-keyed map
      # safe_atomize converts known string tool names to atoms
      assert tc.id == "tc1"
      assert tc.name == :read_file
      assert tc.arguments == %{"path" => "a.ex"}
    end

    test "tool_call with nil id gets generated safe ID (be7 sanitize)" do
      # (code_puppy-be7) Empty/nil tool_call IDs are never persisted — a
      # deterministic safe ID is generated instead so history cannot carry
      # empty tool_call_id values (rejected by some provider APIs).
      msgs = [%{"role" => "user", "content" => "run"}]
      tool_calls = [%{id: nil, name: "read_file", arguments: %{}}]
      ProviderMock.set_response(%{id: "r1", content: "", tool_calls: tool_calls})

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      [tc] = resp.tool_calls
      # Generated ID format: "call_<name>_<unique_integer>"
      assert tc.id =~ ~r/^call_read_file_\d+$/
    end

    test "response with both text and tool_calls" do
      msgs = [%{"role" => "user", "content" => "analyze"}]
      tool_calls = [%{id: "tc1", name: "read_file", arguments: %{"path" => "a.ex"}}]

      ProviderMock.set_response(%{
        id: "r1",
        content: "Let me check that file.",
        tool_calls: tool_calls
      })

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      assert resp.text == "Let me check that file."
      assert length(resp.tool_calls) == 1
    end

    test "string-keyed content in response is extracted" do
      # Provider response may have string-keyed "content"
      msgs = [%{"role" => "user", "content" => "hello"}]

      ProviderMock.set_response(%{
        "id" => "r1",
        "content" => "string-keyed content",
        "tool_calls" => []
      })

      assert {:ok, resp} = LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
      assert resp.text == "string-keyed content"
    end
  end

  # ===========================================================================
  # 5. Error pass-through: {:error, reason} propagates unchanged
  # ===========================================================================

  describe "error pass-through" do
    test "propagates {:error, reason} from provider unchanged" do
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_error(:rate_limited)

      assert {:error, :rate_limited} =
               LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
    end

    test "propagates string error reason" do
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_error("model overloaded")

      assert {:error, "model overloaded"} =
               LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
    end

    test "propagates tuple error reason" do
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_error({:http_error, 429})

      assert {:error, {:http_error, 429}} =
               LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
    end

    test "does not call callback on error" do
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_error(:timeout)

      callback_called = :atomics.new(1, [])

      assert {:error, :timeout} =
               LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ ->
                 :atomics.add(callback_called, 1, 1)
               end)

      assert :atomics.get(callback_called, 1) == 0
    end
  end

  # ===========================================================================
  # 7. Adapter timeout: provider returns :ok but never emits {:done, response}
  # ===========================================================================

  describe "adapter timeout: provider silent :ok" do
    test "returns {:error, :adapter_timeout} when provider :ok without {:done, response}" do
      # Provider returns :ok but never fires {:done, response} → adapter's
      # receive block times out after 5s → {:error, :adapter_timeout}
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_silent_ok()

      task =
        Task.async(fn ->
          LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ -> :ok end)
        end)

      assert {:error, :adapter_timeout} = Task.await(task, 10_000)
    end

    test "adapter does not call upstream callback on silent :ok" do
      msgs = [%{"role" => "user", "content" => "hello"}]
      ProviderMock.set_silent_ok()

      callback_called = :atomics.new(1, [])

      task =
        Task.async(fn ->
          LLMAdapter.stream_chat(msgs, [], [model: "test"], fn _ ->
            :atomics.add(callback_called, 1, 1)
          end)
        end)

      assert {:error, :adapter_timeout} = Task.await(task, 10_000)
      # No events emitted → upstream callback never invoked
      assert :atomics.get(callback_called, 1) == 0
    end
  end
end
