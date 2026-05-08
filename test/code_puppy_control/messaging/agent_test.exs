defmodule CodePuppyControl.Messaging.AgentTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Agent — agent message constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{Agent, WireEvent}

  # ===========================================================================
  # AgentReasoningMessage
  # ===========================================================================

  describe "agent_reasoning_message/1" do
    test "happy path" do
      {:ok, msg} =
        Agent.agent_reasoning_message(%{
          "reasoning" => "I need to check the file first",
          "next_steps" => "Read the config file"
        })

      assert msg["category"] == "agent"
      assert msg["reasoning"] == "I need to check the file first"
      assert msg["next_steps"] == "Read the config file"
    end

    test "nil next_steps is accepted" do
      {:ok, msg} =
        Agent.agent_reasoning_message(%{"reasoning" => "thinking..."})

      assert msg["next_steps"] == nil
    end

    test "rejects missing reasoning" do
      assert {:error, {:missing_required_field, "reasoning"}} =
               Agent.agent_reasoning_message(%{"next_steps" => "x"})
    end

    test "rejects non-string reasoning" do
      assert {:error, {:invalid_field_type, "reasoning", 123}} =
               Agent.agent_reasoning_message(%{"reasoning" => 123})
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "agent", got: "system"}} =
               Agent.agent_reasoning_message(%{
                 "reasoning" => "x",
                 "category" => "system"
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        Agent.agent_reasoning_message(%{
          "reasoning" => "Let me think",
          "next_steps" => "Then act"
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["reasoning"] == "Let me think"
      assert decoded["next_steps"] == "Then act"
    end

    test "WireEvent round-trip" do
      {:ok, msg} = Agent.agent_reasoning_message(%{"reasoning" => "thinking..."})

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["reasoning"] == "thinking..."
      assert restored["category"] == "agent"
    end
  end

  # ===========================================================================
  # AgentResponseMessage
  # ===========================================================================

  describe "agent_response_message/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        Agent.agent_response_message(%{"content" => "Here's your answer"})

      assert msg["category"] == "agent"
      assert msg["content"] == "Here's your answer"
      assert msg["is_markdown"] == false
      assert msg["was_streamed"] == false
      assert msg["streamed_line_count"] == 0
    end

    test "overrides defaults" do
      {:ok, msg} =
        Agent.agent_response_message(%{
          "content" => "# Title",
          "is_markdown" => true,
          "was_streamed" => true,
          "streamed_line_count" => 5
        })

      assert msg["is_markdown"] == true
      assert msg["was_streamed"] == true
      assert msg["streamed_line_count"] == 5
    end

    test "rejects negative streamed_line_count" do
      assert {:error, {:value_below_min, "streamed_line_count", -1, 0}} =
               Agent.agent_response_message(%{
                 "content" => "x",
                 "streamed_line_count" => -1
               })
    end

    test "rejects non-integer streamed_line_count" do
      assert {:error, {:invalid_field_type, "streamed_line_count", "5"}} =
               Agent.agent_response_message(%{
                 "content" => "x",
                 "streamed_line_count" => "5"
               })
    end

    test "rejects missing content" do
      assert {:error, {:missing_required_field, "content"}} =
               Agent.agent_response_message(%{})
    end

    test "WireEvent round-trip preserves streaming fields" do
      {:ok, msg} =
        Agent.agent_response_message(%{
          "content" => "Streamed output",
          "was_streamed" => true,
          "streamed_line_count" => 3
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["was_streamed"] == true
      assert restored["streamed_line_count"] == 3
    end
  end

  # ===========================================================================
  # SubAgentInvocationMessage
  # ===========================================================================

  describe "sub_agent_invocation_message/1" do
    test "happy path" do
      {:ok, msg} =
        Agent.sub_agent_invocation_message(%{
          "agent_name" => "code-puppy",
          "session_id" => "sess-123",
          "prompt" => "Fix the bug",
          "is_new_session" => true
        })

      assert msg["agent_name"] == "code-puppy"
      assert msg["session_id"] == "sess-123"
      assert msg["prompt"] == "Fix the bug"
      assert msg["is_new_session"] == true
      assert msg["message_count"] == 0
    end

    test "defaults message_count to 0" do
      {:ok, msg} =
        Agent.sub_agent_invocation_message(%{
          "agent_name" => "a",
          "session_id" => "s",
          "prompt" => "p",
          "is_new_session" => false
        })

      assert msg["message_count"] == 0
    end

    test "accepts explicit message_count" do
      {:ok, msg} =
        Agent.sub_agent_invocation_message(%{
          "agent_name" => "a",
          "session_id" => "s",
          "prompt" => "p",
          "is_new_session" => false,
          "message_count" => 5
        })

      assert msg["message_count"] == 5
    end

    test "rejects negative message_count" do
      assert {:error, {:value_below_min, "message_count", -1, 0}} =
               Agent.sub_agent_invocation_message(%{
                 "agent_name" => "a",
                 "session_id" => "s",
                 "prompt" => "p",
                 "is_new_session" => true,
                 "message_count" => -1
               })
    end

    test "rejects missing is_new_session" do
      assert {:error, {:missing_required_field, "is_new_session"}} =
               Agent.sub_agent_invocation_message(%{
                 "agent_name" => "a",
                 "session_id" => "s",
                 "prompt" => "p"
               })
    end
  end

  # ===========================================================================
  # SubAgentResponseMessage
  # ===========================================================================

  describe "sub_agent_response_message/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        Agent.sub_agent_response_message(%{
          "agent_name" => "code-puppy",
          "session_id" => "sess-123",
          "response" => "Bug fixed!"
        })

      assert msg["was_streamed"] == false
      assert msg["streamed_line_count"] == 0
      assert msg["message_count"] == 0
    end

    test "rejects missing response" do
      assert {:error, {:missing_required_field, "response"}} =
               Agent.sub_agent_response_message(%{
                 "agent_name" => "a",
                 "session_id" => "s"
               })
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Agent.sub_agent_response_message(%{
          "agent_name" => "qa-kitten",
          "session_id" => "sess-999",
          "response" => "All tests pass",
          "was_streamed" => true,
          "streamed_line_count" => 2
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["agent_name"] == "qa-kitten"
      assert restored["was_streamed"] == true
    end
  end

  # ===========================================================================
  # SubAgentStatusMessage
  # ===========================================================================

  describe "sub_agent_status_message/1" do
    @valid_statuses ~w(starting running thinking tool_calling completed error)

    test "happy path with all valid statuses" do
      for status <- @valid_statuses do
        assert {:ok, msg} =
                 Agent.sub_agent_status_message(%{
                   "session_id" => "s1",
                   "agent_name" => "a",
                   "model_name" => "gpt-4",
                   "status" => status
                 })

        assert msg["status"] == status
      end
    end

    test "defaults numeric fields" do
      {:ok, msg} =
        Agent.sub_agent_status_message(%{
          "session_id" => "s",
          "agent_name" => "a",
          "model_name" => "m",
          "status" => "running"
        })

      assert msg["tool_call_count"] == 0
      assert msg["token_count"] == 0
      assert msg["current_tool"] == nil
      assert msg["elapsed_seconds"] == 0.0
      assert msg["error_message"] == nil
    end

    test "accepts float elapsed_seconds" do
      {:ok, msg} =
        Agent.sub_agent_status_message(%{
          "session_id" => "s",
          "agent_name" => "a",
          "model_name" => "m",
          "status" => "running",
          "elapsed_seconds" => 12.5
        })

      assert msg["elapsed_seconds"] == 12.5
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_literal, "status", "crashed", @valid_statuses}} =
               Agent.sub_agent_status_message(%{
                 "session_id" => "s",
                 "agent_name" => "a",
                 "model_name" => "m",
                 "status" => "crashed"
               })
    end

    test "rejects negative elapsed_seconds" do
      assert {:error, {:value_below_min, "elapsed_seconds", -1.0, 0}} =
               Agent.sub_agent_status_message(%{
                 "session_id" => "s",
                 "agent_name" => "a",
                 "model_name" => "m",
                 "status" => "running",
                 "elapsed_seconds" => -1.0
               })
    end

    test "rejects negative tool_call_count" do
      assert {:error, {:value_below_min, "tool_call_count", -1, 0}} =
               Agent.sub_agent_status_message(%{
                 "session_id" => "s",
                 "agent_name" => "a",
                 "model_name" => "m",
                 "status" => "running",
                 "tool_call_count" => -1
               })
    end

    test "error status with error_message" do
      {:ok, msg} =
        Agent.sub_agent_status_message(%{
          "session_id" => "s",
          "agent_name" => "a",
          "model_name" => "m",
          "status" => "error",
          "error_message" => "Rate limit exceeded"
        })

      assert msg["status"] == "error"
      assert msg["error_message"] == "Rate limit exceeded"
    end

    test "JSON round-trip" do
      {:ok, msg} =
        Agent.sub_agent_status_message(%{
          "session_id" => "s",
          "agent_name" => "a",
          "model_name" => "m",
          "status" => "thinking",
          "current_tool" => "read_file"
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["status"] == "thinking"
      assert decoded["current_tool"] == "read_file"
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Agent.sub_agent_status_message(%{
          "session_id" => "s",
          "agent_name" => "a",
          "model_name" => "m",
          "status" => "tool_calling",
          "tool_call_count" => 3,
          "token_count" => 1500
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["status"] == "tool_calling"
      assert restored["tool_call_count"] == 3
      assert restored["token_count"] == 1500
    end
  end
end
