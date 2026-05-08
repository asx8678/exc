defmodule CodePuppyControl.Tools.SubagentContextTest do
  @moduledoc "Tests for the SubagentContext tools."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.SubagentContext
  alias CodePuppyControl.Tools.SubagentContext.{GetContext, PushContext, PopContext}

  # Each test runs in its own process, so process dictionary is isolated

  describe "GetContext" do
    test "name/0 returns :get_subagent_context" do
      assert GetContext.name() == :get_subagent_context
    end

    test "invoke/2 returns depth=0 for main agent" do
      assert {:ok, result} = GetContext.invoke(%{}, %{})
      assert result.depth == 0
      assert result.is_subagent == false
      assert result.name == nil
    end
  end

  describe "PushContext" do
    test "name/0 returns :push_subagent_context" do
      assert PushContext.name() == :push_subagent_context
    end

    test "invoke/2 pushes context" do
      assert {:ok, result} = PushContext.invoke(%{"agent_name" => "retriever"}, %{})
      assert result.depth == 1
      assert result.name == "retriever"
      assert result.is_subagent == true
    end
  end

  describe "PopContext" do
    test "name/0 returns :pop_subagent_context" do
      assert PopContext.name() == :pop_subagent_context
    end

    test "invoke/2 fails when no context to pop" do
      assert {:error, reason} = PopContext.invoke(%{}, %{})
      assert reason =~ "No sub-agent context to pop"
    end
  end

  describe "push/pop/get_depth/get_name lifecycle" do
    test "full push/pop cycle" do
      assert SubagentContext.get_depth() == 0
      assert SubagentContext.get_name() == nil

      SubagentContext.push("coder")
      assert SubagentContext.get_depth() == 1
      assert SubagentContext.get_name() == "coder"
      assert SubagentContext.is_subagent?() == true

      assert {:ok, %{depth: 0}} = SubagentContext.pop()
      assert SubagentContext.get_depth() == 0
      assert SubagentContext.is_subagent?() == false
    end

    test "nested push/pop" do
      SubagentContext.push("outer")
      assert SubagentContext.get_depth() == 1

      SubagentContext.push("inner")
      assert SubagentContext.get_depth() == 2
      assert SubagentContext.get_name() == "inner"
      assert SubagentContext.get_parent_chain() == ["outer"]

      assert {:ok, _} = SubagentContext.pop()
      assert SubagentContext.get_depth() == 1
      assert SubagentContext.get_name() == "outer"

      assert {:ok, _} = SubagentContext.pop()
      assert SubagentContext.get_depth() == 0
    end
  end

  describe "register_all/0" do
    test "registers all subagent context tools" do
      {:ok, count} = SubagentContext.register_all()
      assert count >= 0
    end
  end
end
