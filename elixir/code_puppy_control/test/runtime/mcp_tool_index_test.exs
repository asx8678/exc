defmodule CodePuppyControl.Runtime.MCPToolIndexTest do
  @moduledoc """
  Tests for MCP.ToolIndex — ETS-backed tool discovery.

  Validates register/unregister, find_server_for_tool, and listing operations.
  async: false because we share the singleton ETS table.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.MCP.ToolIndex

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ToolIndex)

    # Clear all tools before each test
    for {key, _} <- :ets.tab2list(:mcp_tool_index) do
      :ets.delete(:mcp_tool_index, key)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Register Tools
  # ---------------------------------------------------------------------------

  describe "register_tools/2" do
    test "registers tools for a server" do
      tools = [
        %{"name" => "read_file", "description" => "Read a file"},
        %{"name" => "write_file", "description" => "Write a file"}
      ]

      assert :ok = ToolIndex.register_tools("test-server-1", tools)
    end

    test "replaces existing tools on re-registration" do
      tools_v1 = [%{"name" => "old_tool"}]
      tools_v2 = [%{"name" => "new_tool"}]

      ToolIndex.register_tools("test-server-2", tools_v1)
      assert {:ok, "test-server-2"} = ToolIndex.find_server_for_tool("old_tool")

      ToolIndex.register_tools("test-server-2", tools_v2)
      assert :error = ToolIndex.find_server_for_tool("old_tool")
      assert {:ok, "test-server-2"} = ToolIndex.find_server_for_tool("new_tool")
    end

    test "handles atom-keyed tools" do
      tools = [%{name: "search", description: "Search"}]
      assert :ok = ToolIndex.register_tools("atom-server", tools)
      assert {:ok, "atom-server"} = ToolIndex.find_server_for_tool("search")
    end

    test "skips tools without a name" do
      tools = [%{"description" => "Nameless"}, %{"name" => "named_tool"}]
      assert :ok = ToolIndex.register_tools("no-name-server", tools)
      assert :error = ToolIndex.find_server_for_tool("description")
      assert {:ok, "no-name-server"} = ToolIndex.find_server_for_tool("named_tool")
    end
  end

  # ---------------------------------------------------------------------------
  # Unregister
  # ---------------------------------------------------------------------------

  describe "unregister_server/1" do
    test "removes all tools for a server" do
      tools = [%{"name" => "tool_a"}, %{"name" => "tool_b"}]
      ToolIndex.register_tools("unreg-server", tools)

      assert {:ok, "unreg-server"} = ToolIndex.find_server_for_tool("tool_a")

      assert :ok = ToolIndex.unregister_server("unreg-server")
      assert :error = ToolIndex.find_server_for_tool("tool_a")
      assert :error = ToolIndex.find_server_for_tool("tool_b")
    end

    test "does not affect other servers" do
      ToolIndex.register_tools("keep-server", [%{"name" => "keep_tool"}])
      ToolIndex.register_tools("remove-server", [%{"name" => "remove_tool"}])

      ToolIndex.unregister_server("remove-server")

      assert {:ok, "keep-server"} = ToolIndex.find_server_for_tool("keep_tool")
      assert :error = ToolIndex.find_server_for_tool("remove_tool")
    end
  end

  # ---------------------------------------------------------------------------
  # Find Server
  # ---------------------------------------------------------------------------

  describe "find_server_for_tool/1" do
    test "returns error for unknown tool" do
      assert :error = ToolIndex.find_server_for_tool("does_not_exist")
    end

    test "finds server for registered tool" do
      ToolIndex.register_tools("find-server", [%{"name" => "find_me"}])
      assert {:ok, "find-server"} = ToolIndex.find_server_for_tool("find_me")
    end
  end

  # ---------------------------------------------------------------------------
  # List / Get
  # ---------------------------------------------------------------------------

  describe "list_all_tools/0" do
    test "lists all tool-server pairs" do
      ToolIndex.register_tools("list-s1", [%{"name" => "t1"}])
      ToolIndex.register_tools("list-s2", [%{"name" => "t2"}, %{"name" => "t3"}])

      all_tools = ToolIndex.list_all_tools()
      assert {"t1", "list-s1"} in all_tools
      assert {"t2", "list-s2"} in all_tools
      assert {"t3", "list-s2"} in all_tools
    end
  end

  describe "get_tools/1" do
    test "returns tools for a specific server" do
      tools = [%{"name" => "g1"}, %{"name" => "g2"}]
      ToolIndex.register_tools("get-server", tools)

      found = ToolIndex.get_tools("get-server")
      assert length(found) == 2
    end

    test "returns empty list for unknown server" do
      assert [] = ToolIndex.get_tools("unknown-server-999")
    end
  end

  describe "server_summary/0" do
    test "returns map of server_id to tool count" do
      ToolIndex.register_tools("summary-s1", [%{"name" => "a"}])
      ToolIndex.register_tools("summary-s2", [%{"name" => "b"}, %{"name" => "c"}])

      summary = ToolIndex.server_summary()
      assert summary["summary-s1"] == 1
      assert summary["summary-s2"] == 2
    end
  end
end
