defmodule CodePuppyControl.CLI.SlashCommands.Commands.SessionTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State, as: AgentState
  alias CodePuppyControl.CLI.SlashCommands.Commands.Session
  alias CodePuppyControl.REPL.Loop

  # Unique session key per test to avoid cross-test state pollution
  defp unique_key(prefix) do
    rand = :rand.uniform(1_000_000)
    {"#{prefix}-#{rand}", "test-agent-#{rand}"}
  end

  defp make_state(session_id, agent_name \\ "test-agent") do
    %Loop{
      agent: agent_name,
      model: "gpt-4",
      session_id: session_id,
      running: true
    }
  end

  defp sample_messages(count) do
    for i <- 1..count do
      %{"role" => "user", "parts" => [%{"content" => "message #{i}"}]}
    end
  end

  defp user_msg(content) do
    %{"role" => "user", "parts" => [%{"content" => content}]}
  end

  defp assistant_msg(content) do
    %{"role" => "assistant", "parts" => [%{"content" => content}]}
  end

  defp system_msg(content) do
    %{"role" => "system", "parts" => [%{"content" => content}]}
  end

  defp instructions_msg(content) do
    %{"role" => "instructions", "parts" => [%{"content" => content}]}
  end

  # ── /compact ───────────────────────────────────────────────────────────

  describe "/compact" do
    test "with no session_id prints error" do
      state = make_state(nil)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_compact("/compact", state)
        end)

      assert output =~ "No active session"
      assert output =~ IO.ANSI.red()
    end

    test "with empty history prints warning" do
      {session_id, agent_name} = unique_key("compact-empty")
      state = make_state(session_id, agent_name)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_compact("/compact", state)
        end)

      assert output =~ "No history to compact"
      assert output =~ IO.ANSI.yellow()
    end

    test "with history compacts and writes back" do
      {session_id, agent_name} = unique_key("compact-real")
      state = make_state(session_id, agent_name)

      # Create enough messages to trigger meaningful compaction
      messages =
        [system_msg("You are helpful.")] ++
          sample_messages(20)

      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_compact("/compact", state)
        end)

      # Should show compaction result
      assert output =~ "Compacted"
      assert output =~ IO.ANSI.green()

      # Verify history was actually written back
      final_messages = AgentState.get_messages(session_id, agent_name)
      assert is_list(final_messages)
      # Compaction should reduce or maintain message count
      assert length(final_messages) <= length(messages)
    end

    test "output includes compaction stats" do
      {session_id, agent_name} = unique_key("compact-stats")
      state = make_state(session_id, agent_name)

      messages =
        [system_msg("sys")] ++
          sample_messages(30)

      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_compact("/compact", state)
        end)

      # Stats should include at least one of these fields
      assert output =~ "dropped=" or output =~ "truncated=" or
               output =~ "summarize_candidates="
    end
  end

  # ── /truncate ──────────────────────────────────────────────────────────

  describe "/truncate" do
    test "with no argument prints usage error" do
      state = make_state("any")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate", state)
        end)

      assert output =~ "Usage"
      assert output =~ IO.ANSI.red()
    end

    test "with invalid number prints error" do
      state = make_state("any")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate abc", state)
        end)

      assert output =~ "Invalid number"
      assert output =~ IO.ANSI.red()
    end

    test "with zero prints invalid number error" do
      state = make_state("any")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 0", state)
        end)

      assert output =~ "Invalid number"
    end

    test "with negative number prints invalid number error" do
      state = make_state("any")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate -5", state)
        end)

      assert output =~ "Invalid number"
    end

    test "with no session_id prints error" do
      state = make_state(nil)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 5", state)
        end)

      assert output =~ "No active session"
      assert output =~ IO.ANSI.red()
    end

    test "with empty history prints warning" do
      {session_id, agent_name} = unique_key("truncate-empty")
      state = make_state(session_id, agent_name)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 5", state)
        end)

      assert output =~ "No history to truncate"
      assert output =~ IO.ANSI.yellow()
    end

    test "with history shorter than N prints nothing-to-do message" do
      {session_id, agent_name} = unique_key("truncate-short")
      state = make_state(session_id, agent_name)

      messages = sample_messages(3)
      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 10", state)
        end)

      assert output =~ "already has 3 messages"
      assert output =~ "Nothing to truncate"
    end

    test "truncates to N messages, keeping system message" do
      {session_id, agent_name} = unique_key("truncate-real")
      state = make_state(session_id, agent_name)

      sys = system_msg("You are helpful.")
      messages = [sys | sample_messages(9)]
      # 1 system + 9 user = 10 messages
      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 4", state)
        end)

      assert output =~ "Truncated"
      assert output =~ "10 → 4 messages"
      assert output =~ IO.ANSI.green()

      # Verify actual state: system message + 3 most recent
      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 4
      assert hd(final) == sys
      # Last 3 should be the last 3 from original
      assert List.last(final) == List.last(messages)
    end

    test "with N=1 keeps only system message" do
      {session_id, agent_name} = unique_key("truncate-n1")
      state = make_state(session_id, agent_name)

      sys = system_msg("sys")
      messages = [sys | sample_messages(5)]
      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 1", state)
        end)

      assert output =~ "Truncated"
      assert output =~ IO.ANSI.green()

      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 1
      assert hd(final) == sys
    end

    test "with history exactly N messages prints nothing-to-do" do
      {session_id, agent_name} = unique_key("truncate-exact")
      state = make_state(session_id, agent_name)

      messages = sample_messages(5)
      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 5", state)
        end)

      assert output =~ "already has 5 messages"
    end
  end

  # ── Regression: agent key resolution (fix #1) ──────────────────

  describe "agent key resolution" do
    test "kebab-case display name resolves to snake_case catalogue key" do
      # "code-puppy" is the REPL display string; the catalogue key is "code_puppy"
      assert {:ok, "code_puppy"} = Loop.resolve_agent_key("code-puppy")
    end

    test "snake_case name resolves as-is" do
      assert {:ok, "code_puppy"} = Loop.resolve_agent_key("code_puppy")
    end

    test "unknown agent name returns error" do
      assert {:error, _} = Loop.resolve_agent_key("nonexistent-agent-xyz")
    end

    test "session commands resolve agent key from kebab-case state.agent" do
      # Use a known catalogue agent name in kebab-case as the REPL would
      {session_id, _} = unique_key("key-resolve")
      # Simulate what the REPL does: state.agent is kebab-case display string
      state = make_state(session_id, "code-puppy")

      messages = [system_msg("sys") | sample_messages(5)]
      # Set messages under the *resolved* key (snake_case)
      AgentState.set_messages(session_id, "code_puppy", messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 3", state)
        end)

      assert output =~ "Truncated"
      # Verify the messages were read from the correct key
      final = AgentState.get_messages(session_id, "code_puppy")
      assert length(final) == 3
      assert hd(final) == system_msg("sys")
    end
  end

  # ── Regression: /truncate with non-system first message (fix #2) ─

  describe "/truncate with non-system first message" do
    test "user-first history: keeps last N messages without preserving first" do
      {session_id, agent_name} = unique_key("truncate-user-first")
      state = make_state(session_id, agent_name)

      # Runtime-shaped history: starts with user, no system preamble
      messages = [
        user_msg("hello"),
        assistant_msg("hi there"),
        user_msg("how are you"),
        assistant_msg("fine thanks"),
        user_msg("good"),
        assistant_msg("great")
      ]

      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 3", state)
        end)

      assert output =~ "Truncated"
      assert output =~ "6 → 3 messages"
      # Label should say "keeping N most recent", not "keeping system message"
      assert output =~ "keeping 3 most recent"

      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 3
      # Should be the last 3 messages from the original list
      assert final == Enum.take(messages, -3)
    end

    test "instructions-first history: preserves instructions message" do
      {session_id, agent_name} = unique_key("truncate-instructions")
      state = make_state(session_id, agent_name)

      instr = instructions_msg("Follow these rules")
      messages = [instr, user_msg("q1"), assistant_msg("a1"), user_msg("q2"), assistant_msg("a2")]

      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 3", state)
        end)

      assert output =~ "Truncated"
      assert output =~ "keeping system message"

      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 3
      assert hd(final) == instr
    end

    test "user-first history with N=1 keeps only last message" do
      {session_id, agent_name} = unique_key("truncate-user-n1")
      state = make_state(session_id, agent_name)

      messages = [user_msg("a"), assistant_msg("b"), user_msg("c")]
      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 1", state)
        end)

      assert output =~ "Truncated"

      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 1
      # Should be the last message, not the first
      assert hd(final) == user_msg("c")
    end

    test "system-first history with N=1 keeps only system message" do
      {session_id, agent_name} = unique_key("truncate-sys-n1")
      state = make_state(session_id, agent_name)

      sys = system_msg("you are helpful")
      messages = [sys, user_msg("a"), assistant_msg("b")]
      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 1", state)
        end)

      assert output =~ "Truncated"

      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 1
      assert hd(final) == sys
    end

    test "mixed user/assistant history: truncate preserves correct messages" do
      {session_id, agent_name} = unique_key("truncate-mixed")
      state = make_state(session_id, agent_name)

      messages =
        for i <- 1..10 do
          if rem(i, 2) == 1 do
            user_msg("q#{i}")
          else
            assistant_msg("a#{i}")
          end
        end

      AgentState.set_messages(session_id, agent_name, messages)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Session.handle_truncate("/truncate 4", state)
        end)

      assert output =~ "Truncated"
      assert output =~ "10 → 4 messages"
      assert output =~ "keeping 4 most recent"

      final = AgentState.get_messages(session_id, agent_name)
      assert length(final) == 4
      assert final == Enum.take(messages, -4)
    end
  end
end
