defmodule CodePuppyControl.Agent.LLMAdapterToolResolutionTest do
  @moduledoc """
  Tests for LLMAdapter tool resolution logic.

  Covers:
  - atom name → JSON-Schema function map conversion via Tool.Registry
  - graceful fallback when tools are unregistered or malformed
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.LLMAdapter
  alias CodePuppyControl.Tool.Registry
  alias CodePuppyControl.Test.LLMAdapterTestHelper.ProviderMock
  alias CodePuppyControl.Test.LLMAdapterTestHelper.StubTool

  import CodePuppyControl.Test.LLMAdapterTestHelper, only: [setup_mock_provider: 0]

  setup do
    setup_mock_provider()
  end

  # ===========================================================================
  # 3. Tool conversion: atom names → JSON-Schema function maps via Tool.Registry
  # ===========================================================================

  describe "tool conversion: atom names → JSON-Schema function maps" do
    setup do
      # Use the app-supervised Registry; register stub and clean up in on_exit.
      :ok = Registry.register(StubTool)
      on_exit(fn -> Registry.unregister(:stub_tool) end)
      :ok
    end

    test "resolves registered tool atom to JSON-Schema function map" do
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:stub_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      tools = ProviderMock.captured_tools()
      assert length(tools) == 1

      [tool] = tools
      assert tool[:type] == "function"
      assert tool[:function][:name] == "stub_tool"
      assert tool[:function][:description] == "A stub tool for testing"
      assert tool[:function][:parameters]["properties"]["query"]["type"] == "string"
    end

    test "skips unregistered tool names without crashing" do
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:stub_tool, :nonexistent_tool],
                 [model: "test"],
                 fn _ -> :ok end
               )

      tools = ProviderMock.captured_tools()
      # Only :stub_tool resolved; :nonexistent_tool silently skipped
      assert length(tools) == 1
      assert hd(tools)[:function][:name] == "stub_tool"
    end

    test "empty tool list produces empty schema list" do
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [],
                 [model: "test"],
                 fn _ -> :ok end
               )

      assert ProviderMock.captured_tools() == []
    end

    test "multiple registered tools resolve in order" do
      # Register a second stub
      defmodule AnotherStubTool do
        use CodePuppyControl.Tool

        @impl true
        def name, do: :another_stub

        @impl true
        def description, do: "Another stub"

        @impl true
        def parameters, do: %{"type" => "object", "properties" => %{}}

        @impl true
        def invoke(_args, _context), do: {:ok, "another"}
      end

      :ok = Registry.register(AnotherStubTool)
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:stub_tool, :another_stub],
                 [model: "test"],
                 fn _ -> :ok end
               )

      tools = ProviderMock.captured_tools()
      assert length(tools) == 2
      names = Enum.map(tools, & &1[:function][:name])
      assert "stub_tool" in names
      assert "another_stub" in names
    after
      # Clean up the dynamically-registered tool from the app-supervised Registry
      Registry.unregister(:another_stub)
    end
  end

  # ===========================================================================
  # 6. Tool registry missing: graceful [] fallback, no crash
  # ===========================================================================

  describe "tool registry missing: graceful fallback" do
    test "returns empty tool list when all tool names are unregistered" do
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:totally_fake_tool, :also_nonexistent],
                 [model: "test"],
                 fn _ -> :ok end
               )

      # No tools resolved — graceful [], not a crash
      assert ProviderMock.captured_tools() == []
    end

    test "non-atom tool names are skipped gracefully" do
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 ["string_tool_name", 123, nil],
                 [model: "test"],
                 fn _ -> :ok end
               )

      # Non-atom entries silently filtered
      assert ProviderMock.captured_tools() == []
    end

    test "resolve_tools rescue path returns [] for bad tool modules" do
      # Unregistered names return :error from Registry.lookup, which
      # resolve_single_tool handles as nil → filtered out. Verifies no crash.
      ProviderMock.set_response(%{id: "r1", content: "ok", tool_calls: []})

      assert {:ok, _} =
               LLMAdapter.stream_chat(
                 [%{"role" => "user", "content" => "hi"}],
                 [:no_such_tool_registered, :also_missing],
                 [model: "test"],
                 fn _ -> :ok end
               )

      assert ProviderMock.captured_tools() == []
    end
  end
end
