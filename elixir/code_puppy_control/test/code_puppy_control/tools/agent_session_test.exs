defmodule CodePuppyControl.Tools.AgentSessionTest do
  @moduledoc """
  Tests for the AgentSession module.

  Covers:
  - Session ID validation (valid, invalid, too long, special chars)
  - Session ID sanitization (dots → hyphens, underscores → hyphens)
  - Session save and load round-trip
  - Missing session returns empty list
  - Session directory creation
  - Session listing and deletion
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.AgentSession

  # ----------------------------------------------------------------------------
  # Session ID Validation Tests
  # ----------------------------------------------------------------------------

  describe "validate_session_id/1" do
    test "accepts valid kebab-case IDs" do
      assert :ok = AgentSession.validate_session_id("my-session")
      assert :ok = AgentSession.validate_session_id("agent-session-1")
      assert :ok = AgentSession.validate_session_id("discussion-about-code")
      assert :ok = AgentSession.validate_session_id("a-b-c-d-e")
      assert :ok = AgentSession.validate_session_id("code-puppy-rjl1-14-worktree")
      assert :ok = AgentSession.validate_session_id("session123")
      assert :ok = AgentSession.validate_session_id("test")
      assert :ok = AgentSession.validate_session_id("a1")
    end

    test "rejects uppercase letters" do
      assert {:error, _} = AgentSession.validate_session_id("MySession")
      assert {:error, _} = AgentSession.validate_session_id("My-Session")
      assert {:error, _} = AgentSession.validate_session_id("session-ABC")
    end

    test "rejects underscores" do
      assert {:error, _} = AgentSession.validate_session_id("my_session")
      assert {:error, _} = AgentSession.validate_session_id("test_session_123")
    end

    test "rejects spaces" do
      assert {:error, _} = AgentSession.validate_session_id("my session")
      assert {:error, _} = AgentSession.validate_session_id("test session 123")
    end

    test "rejects double hyphens" do
      assert {:error, _} = AgentSession.validate_session_id("my--session")
      assert {:error, _} = AgentSession.validate_session_id("test--123")
    end

    test "rejects leading hyphens" do
      assert {:error, _} = AgentSession.validate_session_id("-session")
    end

    test "rejects trailing hyphens" do
      assert {:error, _} = AgentSession.validate_session_id("session-")
    end

    test "rejects special characters" do
      assert {:error, _} = AgentSession.validate_session_id("my@session")
      assert {:error, _} = AgentSession.validate_session_id("test#123")
      assert {:error, _} = AgentSession.validate_session_id("session$id")
      assert {:error, _} = AgentSession.validate_session_id("test.123")
    end

    test "rejects empty string" do
      assert {:error, "session_id cannot be empty"} = AgentSession.validate_session_id("")
    end

    test "rejects non-string values" do
      assert {:error, "session_id must be a string"} = AgentSession.validate_session_id(nil)
      assert {:error, "session_id must be a string"} = AgentSession.validate_session_id(123)
      assert {:error, "session_id must be a string"} = AgentSession.validate_session_id(:atom)
    end

    test "rejects IDs that are too long" do
      long_id = String.duplicate("a", 129)
      assert {:error, _} = AgentSession.validate_session_id(long_id)

      # But 128 chars should be fine
      ok_id = String.duplicate("a", 128)
      assert :ok = AgentSession.validate_session_id(ok_id)
    end
  end

  # ----------------------------------------------------------------------------
  # Session ID Sanitization Tests
  # ----------------------------------------------------------------------------

  describe "sanitize_session_id/1" do
    test "lowercases strings" do
      assert "mysession" = AgentSession.sanitize_session_id("MySession")
      assert "test-session" = AgentSession.sanitize_session_id("Test-Session")
    end

    test "replaces dots with hyphens" do
      assert "code-puppy-rjl1-14-worktree" =
               AgentSession.sanitize_session_id("code_puppy-rjl1.14-worktree")

      assert "version-1-2-3" = AgentSession.sanitize_session_id("version.1.2.3")
    end

    test "replaces underscores with hyphens" do
      assert "my-session" = AgentSession.sanitize_session_id("my_session")
      assert "test-123-test" = AgentSession.sanitize_session_id("test_123_test")
    end

    test "collapses multiple hyphens into single hyphen" do
      assert "a-b-c" = AgentSession.sanitize_session_id("a---b---c")
      assert "test" = AgentSession.sanitize_session_id("test---")
    end

    test "strips leading and trailing hyphens" do
      assert "session" = AgentSession.sanitize_session_id("-session")
      assert "session" = AgentSession.sanitize_session_id("session-")
      assert "session" = AgentSession.sanitize_session_id("-session-")
    end

    test "replaces special characters with hyphens" do
      assert "my-session" = AgentSession.sanitize_session_id("my@session")
      assert "test-123" = AgentSession.sanitize_session_id("test#123")
      assert "session-id" = AgentSession.sanitize_session_id("session$id")
    end

    test "truncates to 128 characters" do
      long = String.duplicate("a", 200)
      sanitized = AgentSession.sanitize_session_id(long)
      assert String.length(sanitized) <= 128
      assert Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, sanitized)
    end

    test "falls back to 'session' for empty result" do
      assert "session" = AgentSession.sanitize_session_id("!!!")
      assert "session" = AgentSession.sanitize_session_id("@@@")
      assert "session" = AgentSession.sanitize_session_id("---")
      assert "session" = AgentSession.sanitize_session_id("")
    end

    test "handles complex mixed cases" do
      assert "my-awesome-session-123" =
               AgentSession.sanitize_session_id("My_Awesome.Session__123!!")
    end

    test "handles non-string inputs by converting to string" do
      assert "123" = AgentSession.sanitize_session_id(123)
      assert "atom" = AgentSession.sanitize_session_id(:atom)
    end
  end

  # ----------------------------------------------------------------------------
  # Session Persistence Tests
  # ----------------------------------------------------------------------------

  describe "save_session_history/3 and load_session_history/1" do
    test "round-trip save and load" do
      session_id = "test-roundtrip-#{System.unique_integer([:positive])}"
      agent_name = "test-agent"

      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant"},
        %{"role" => "user", "content" => "Hello!"},
        %{"role" => "assistant", "content" => "Hi there!"}
      ]

      # Save the session
      assert :ok = AgentSession.save_session_history(session_id, messages, agent_name)

      # Load the session
      assert {:ok, result} = AgentSession.load_session_history(session_id)

      # Verify messages
      assert result.messages == messages

      # Verify metadata
      assert result.metadata["session_id"] == session_id
      assert result.metadata["agent_name"] == agent_name
      assert result.metadata["message_count"] == 3
      assert result.metadata["initial_prompt"] == nil
      assert is_binary(result.metadata["created_at"])
      assert is_binary(result.metadata["updated_at"])
    end

    test "save with initial_prompt preserves it" do
      session_id = "test-prompt-#{System.unique_integer([:positive])}"
      agent_name = "test-agent"
      initial_prompt = "Hello, please help me with this task"

      messages = [%{"role" => "user", "content" => "Test"}]

      assert :ok =
               AgentSession.save_session_history(session_id, messages, agent_name, initial_prompt)

      assert {:ok, result} = AgentSession.load_session_history(session_id)
      assert result.metadata["initial_prompt"] == initial_prompt
    end

    test "save preserves initial_prompt from previous save" do
      session_id = "test-preserve-#{System.unique_integer([:positive])}"
      agent_name = "test-agent"
      initial_prompt = "Original prompt"

      # First save with initial_prompt
      assert :ok =
               AgentSession.save_session_history(
                 session_id,
                 [%{"role" => "user", "content" => "First"}],
                 agent_name,
                 initial_prompt
               )

      # Second save without initial_prompt - should preserve original
      assert :ok =
               AgentSession.save_session_history(
                 session_id,
                 [
                   %{"role" => "user", "content" => "First"},
                   %{"role" => "assistant", "content" => "Response"}
                 ],
                 agent_name,
                 nil
               )

      assert {:ok, result} = AgentSession.load_session_history(session_id)
      assert result.metadata["initial_prompt"] == initial_prompt
    end

    test "load non-existent session returns empty messages" do
      session_id = "non-existent-session-#{System.unique_integer([:positive])}"

      assert {:ok, result} = AgentSession.load_session_history(session_id)
      assert result.messages == []
      assert result.metadata == nil
    end

    test "save and load multiple sessions" do
      base_id = System.unique_integer([:positive])

      for i <- 1..3 do
        session_id = "test-multi-#{base_id}-#{i}"
        messages = [%{"role" => "user", "content" => "Message #{i}"}]
        assert :ok = AgentSession.save_session_history(session_id, messages, "agent-#{i}")
      end

      for i <- 1..3 do
        session_id = "test-multi-#{base_id}-#{i}"
        assert {:ok, result} = AgentSession.load_session_history(session_id)
        assert length(result.messages) == 1
        assert result.metadata["agent_name"] == "agent-#{i}"
      end
    end

    test "save validates session_id" do
      assert {:error, _} = AgentSession.save_session_history("INVALID_ID", [], "agent")
    end

    test "load validates session_id" do
      assert {:error, _} = AgentSession.load_session_history("INVALID_ID")
    end

    test "update session maintains created_at but updates updated_at" do
      session_id = "test-timestamps-#{System.unique_integer([:positive])}"

      # First save
      assert :ok =
               AgentSession.save_session_history(
                 session_id,
                 [%{"role" => "user", "content" => "First"}],
                 "agent"
               )

      assert {:ok, first_load} = AgentSession.load_session_history(session_id)
      first_created = first_load.metadata["created_at"]
      first_updated = first_load.metadata["updated_at"]

      # Wait a tiny bit
      Process.sleep(10)

      # Second save
      assert :ok =
               AgentSession.save_session_history(
                 session_id,
                 [%{"role" => "user", "content" => "Second"}],
                 "agent"
               )

      assert {:ok, second_load} = AgentSession.load_session_history(session_id)
      second_created = second_load.metadata["created_at"]
      second_updated = second_load.metadata["updated_at"]

      # created_at should stay the same
      assert first_created == second_created

      # updated_at should be different (and newer)
      assert first_updated != second_updated
    end
  end

  # ----------------------------------------------------------------------------
  # Session Directory Tests
  # ----------------------------------------------------------------------------

  describe "get_sessions_dir/0" do
    test "returns a valid directory path" do
      assert {:ok, path} = AgentSession.get_sessions_dir()
      assert is_binary(path)
      assert File.dir?(path)
    end

    test "directory is accessible for writing" do
      assert {:ok, path} = AgentSession.get_sessions_dir()
      test_file = Path.join(path, ".write_test_#{System.unique_integer()}")
      assert File.write(test_file, "test") == :ok
      File.rm(test_file)
    end
  end

  # ----------------------------------------------------------------------------
  # Session Listing and Deletion Tests
  # ----------------------------------------------------------------------------

  describe "list_sessions/0" do
    test "lists saved sessions" do
      # Create some sessions
      base_id = System.unique_integer([:positive])

      for i <- 1..3 do
        session_id = "list-test-#{base_id}-#{i}"
        assert :ok = AgentSession.save_session_history(session_id, [], "agent")
      end

      # List should include our sessions
      assert {:ok, sessions} = AgentSession.list_sessions()
      assert "list-test-#{base_id}-1" in sessions
      assert "list-test-#{base_id}-2" in sessions
      assert "list-test-#{base_id}-3" in sessions
    end
  end

  describe "delete_session/1" do
    test "deletes an existing session" do
      session_id = "delete-test-#{System.unique_integer([:positive])}"
      assert :ok = AgentSession.save_session_history(session_id, [], "agent")

      # Verify it exists
      assert {:ok, _} = AgentSession.load_session_history(session_id)

      # Delete it
      assert :ok = AgentSession.delete_session(session_id)

      # Verify it's gone
      assert {:ok, result} = AgentSession.load_session_history(session_id)
      assert result.messages == []
    end

    test "deleting non-existent session is ok" do
      session_id = "non-existent-#{System.unique_integer([:positive])}"
      assert :ok = AgentSession.delete_session(session_id)
    end

    test "delete validates session_id" do
      assert {:error, _} = AgentSession.delete_session("INVALID_ID")
    end
  end
end
