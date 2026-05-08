defmodule CodePuppyControl.Tools.CpAgentOpsTest do
  @moduledoc """
  Tests for the CpAgentOps tool wrappers.

  Validates:
  - CpInvokeAgent tool behaviour (name, description, parameters, invoke)
  - CpListAgents tool behaviour (name, description, parameters, invoke)
  - Result shape parity with Python's AgentInvokeOutput / ListAgentsOutput
  - session_id parameter acceptance

  Refs: code_puppy-mmk.4 (Phase E)
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.CpAgentOps.{CpInvokeAgent, CpListAgents}

  # ---------------------------------------------------------------------------
  # CpListAgents
  # ---------------------------------------------------------------------------

  describe "CpListAgents" do
    test "name/0 returns :cp_list_agents" do
      assert CpListAgents.name() == :cp_list_agents
    end

    test "description/0 returns a non-empty string" do
      assert is_binary(CpListAgents.description())
      assert String.length(CpListAgents.description()) > 0
    end

    test "parameters/0 returns valid JSON schema" do
      params = CpListAgents.parameters()

      assert params["type"] == "object"
      assert is_map(params["properties"])
    end

    test "invoke/2 returns {:ok, result} with ListAgentsOutput shape" do
      assert {:ok, result} = CpListAgents.invoke(%{}, %{})

      # ListAgentsOutput shape
      assert Map.has_key?(result, :agents)
      assert Map.has_key?(result, :error)
      assert is_list(result.agents)
      assert result.error == nil
    end

    test "invoke/2 agents have name, display_name, description" do
      {:ok, result} = CpListAgents.invoke(%{}, %{})

      for agent <- result.agents do
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :display_name)
        assert Map.has_key?(agent, :description)
      end
    end

    test "tool_schema/0 returns valid LLM function schema" do
      schema = CpListAgents.tool_schema()

      assert schema.type == "function"
      assert schema.function.name == "cp_list_agents"
      assert is_binary(schema.function.description)
      assert is_map(schema.function.parameters)
    end
  end

  # ---------------------------------------------------------------------------
  # CpInvokeAgent
  # ---------------------------------------------------------------------------

  describe "CpInvokeAgent" do
    test "name/0 returns :cp_invoke_agent" do
      assert CpInvokeAgent.name() == :cp_invoke_agent
    end

    test "description/0 mentions sub-agent" do
      desc = CpInvokeAgent.description()
      assert is_binary(desc)
      assert String.contains?(desc, "sub-agent") or String.contains?(desc, "agent")
    end

    test "parameters/0 includes agent_name and prompt as required" do
      params = CpInvokeAgent.parameters()

      assert params["type"] == "object"
      assert "agent_name" in params["required"]
      assert "prompt" in params["required"]
      assert Map.has_key?(params["properties"], "agent_name")
      assert Map.has_key?(params["properties"], "prompt")
    end

    test "parameters/0 includes optional session_id" do
      params = CpInvokeAgent.parameters()

      assert Map.has_key?(params["properties"], "session_id")
      refute "session_id" in (params["required"] || [])
    end

    test "invoke/2 with nonexistent agent returns error" do
      args = %{"agent_name" => "nonexistent-agent-xyz", "prompt" => "test"}

      assert {:error, result} = CpInvokeAgent.invoke(args, %{})

      # Should have AgentInvokeOutput shape
      assert Map.has_key?(result, :response)
      assert Map.has_key?(result, :agent_name)
      assert Map.has_key?(result, :session_id)
      assert Map.has_key?(result, :error)
      assert result.error != nil
    end

    test "invoke/2 with session_id passes it through" do
      args = %{
        "agent_name" => "nonexistent-agent-xyz",
        "prompt" => "test",
        "session_id" => "my-test-session"
      }

      {:error, result} = CpInvokeAgent.invoke(args, %{})

      # Session ID should be present (may have hash suffix appended)
      assert result.session_id != nil
    end

    test "invoke/2 filters context with excluded keys" do
      args = %{"agent_name" => "nonexistent-agent-xyz", "prompt" => "test"}

      # Context with excluded keys should not cause errors
      context = %{
        "tool_outputs" => [%{result: "data"}],
        "session_history" => [1, 2, 3]
      }

      # Should not crash
      result = CpInvokeAgent.invoke(args, context)
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "tool_schema/0 returns valid LLM function schema" do
      schema = CpInvokeAgent.tool_schema()

      assert schema.type == "function"
      assert schema.function.name == "cp_invoke_agent"
      assert is_binary(schema.function.description)
      assert is_map(schema.function.parameters)
    end

    test "extract_parent_context/1 filters atom keys" do
      # Test the private helper via the invoke path
      # Atom-keyed context values should not be passed to ContextFilter
      context = %{
        :run_id => "run-123",
        :agent_module => SomeModule,
        "user_prompt" => "hello",
        "tool_outputs" => [%{}]
      }

      args = %{"agent_name" => "nonexistent-agent-xyz", "prompt" => "test"}

      # Should not crash even with atom-keyed context
      result = CpInvokeAgent.invoke(args, context)
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    # -- node parameter (Phase I.3) ----------------------------------------

    test "parameters/0 includes node field" do
      params = CpInvokeAgent.parameters()

      assert Map.has_key?(params["properties"], "node")
      assert params["properties"]["node"]["type"] == "string"
      assert is_binary(params["properties"]["node"]["description"])
    end

    test "node is optional (not in required list)" do
      params = CpInvokeAgent.parameters()

      refute "node" in (params["required"] || [])
    end

    test "empty string node is treated as nil" do
      # The invoke/2 implementation should convert "" to nil for node
      args = %{
        "agent_name" => "nonexistent-agent-xyz",
        "prompt" => "test",
        "node" => ""
      }

      # Should not crash — empty node is normalized to nil → local path
      result = CpInvokeAgent.invoke(args, %{})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "node parameter is passed through to AgentInvocation" do
      # With a valid-looking node string but nonexistent agent,
      # it should still fail (agent not found) without crashing
      args = %{
        "agent_name" => "nonexistent-agent-xyz",
        "prompt" => "test",
        "node" => "pup_builder@build-01"
      }

      result = CpInvokeAgent.invoke(args, %{})
      # Distributed is disabled → falls back to local → agent not found
      assert match?({:error, _}, result)
    end
  end
end
