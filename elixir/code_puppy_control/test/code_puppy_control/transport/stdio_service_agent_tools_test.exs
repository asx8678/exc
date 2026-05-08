defmodule CodePuppyControl.Transport.StdioService.AgentToolsTest do
  @moduledoc """
  Tests for agent_tools RPC handlers in stdio_service (code_puppy-mmk.4).

  Covers:
  - agent_tools.list: returns valid ListAgentsOutput shape
  - agent_tools.invoke: validates required params, returns AgentInvokeOutput
  - agent_tools.invoke_headless: validates required params, returns response/error
  - agent_tools.generate_session_id: returns valid session ID
  - Result-shape conversion matches Python AgentInvokeOutput
  """

  use ExUnit.Case, async: true

  # Minimal handle_request simulation — we test the handler logic
  # by calling AgentInvocation directly (the handlers are thin wrappers).

  describe "agent_tools.list" do
    test "returns ListAgentsOutput shape with agents list" do
      result = CodePuppyControl.Tools.AgentInvocation.list_agents()

      assert Map.has_key?(result, :agents)
      assert Map.has_key?(result, :error)
      assert is_list(result.agents)
    end

    test "each agent has required keys" do
      result = CodePuppyControl.Tools.AgentInvocation.list_agents()

      for agent <- result.agents do
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :display_name)
        assert Map.has_key?(agent, :description)
      end
    end
  end

  describe "agent_tools.invoke" do
    test "returns AgentInvokeOutput shape for unknown agent" do
      result =
        CodePuppyControl.Tools.AgentInvocation.invoke(
          "absolutely-nonexistent-agent-rpc-test",
          "test prompt"
        )

      # Must match Python AgentInvokeOutput shape
      assert Map.has_key?(result, :response)
      assert Map.has_key?(result, :agent_name)
      assert Map.has_key?(result, :session_id)
      assert Map.has_key?(result, :error)

      # For unknown agent: response is nil, error is string
      assert result.response == nil
      assert is_binary(result.error)
    end

    test "session_id is generated when not provided" do
      result =
        CodePuppyControl.Tools.AgentInvocation.invoke(
          "nonexistent-rpc-test",
          "test"
        )

      assert result.session_id != nil
      assert String.contains?(result.session_id, "-session-")
    end

    test "prompt is included in invocation event" do
      Phoenix.PubSub.subscribe(CodePuppyControl.PubSub, "global:events")

      CodePuppyControl.Tools.AgentInvocation.invoke(
        "nonexistent-rpc-test",
        "my special prompt"
      )

      assert_receive {:event, %{type: "subagent_invocation", prompt: "my special prompt"}}, 500
    end
  end

  describe "agent_tools.invoke_headless" do
    test "returns error tuple for unknown agent" do
      assert {:error, reason} =
               CodePuppyControl.Tools.AgentInvocation.invoke_headless(
                 "nonexistent-rpc-test",
                 "test"
               )

      assert is_binary(reason)
    end

    test "accepts optional session_id and model" do
      assert {:error, _} =
               CodePuppyControl.Tools.AgentInvocation.invoke_headless(
                 "nonexistent-rpc-test",
                 "test",
                 session_id: "my-session",
                 model: "claude-3"
               )
    end
  end

  describe "agent_tools.generate_session_id" do
    test "returns valid session ID" do
      session_id =
        CodePuppyControl.Tools.AgentInvocation.generate_session_id("code-puppy")

      assert String.starts_with?(session_id, "code-puppy-session-")
      suffix = String.replace_prefix(session_id, "code-puppy-session-", "")
      assert String.length(suffix) == 8
    end

    test "sanitizes agent name" do
      session_id =
        CodePuppyControl.Tools.AgentInvocation.generate_session_id("QA_Expert")

      assert String.starts_with?(session_id, "qa-expert-session-")
    end

    test "generates unique IDs" do
      ids =
        for _ <- 1..20 do
          CodePuppyControl.Tools.AgentInvocation.generate_session_id("test")
        end

      # Extremely unlikely collisions
      assert length(Enum.uniq(ids)) >= 19
    end
  end

  describe "Python parity: result shapes" do
    test "AgentInvokeOutput matches Python model fields" do
      result =
        CodePuppyControl.Tools.AgentInvocation.invoke(
          "nonexistent-rpc-parity",
          "test"
        )

      # Python: AgentInvokeOutput(response, agent_name, session_id, error)
      # All four keys must be present
      assert Map.has_key?(result, :response)
      assert Map.has_key?(result, :agent_name)
      assert Map.has_key?(result, :session_id)
      assert Map.has_key?(result, :error)
    end

    test "ListAgentsOutput matches Python model fields" do
      result = CodePuppyControl.Tools.AgentInvocation.list_agents()

      # Python: ListAgentsOutput(agents, error)
      assert Map.has_key?(result, :agents)
      assert Map.has_key?(result, :error)

      for agent <- result.agents do
        # Python: AgentInfo(name, display_name, description)
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :display_name)
        assert Map.has_key?(agent, :description)
      end
    end

    test "invoke_headless response shape matches Python contract" do
      # Python invoke_agent_headless returns string on success
      # Elixir returns {:ok, string} | {:error, string}
      assert {:error, _} =
               CodePuppyControl.Tools.AgentInvocation.invoke_headless(
                 "nonexistent-rpc-parity",
                 "test"
               )

      # Success case would be: {:ok, "response text"}
    end
  end
end
