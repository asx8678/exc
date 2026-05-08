defmodule CodePuppyControl.Agent.StateTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.State

  # ── message_hash/1 (pure) ─────────────────────────────────────────────

  describe "message_hash/1" do
    test "returns 16-char hex string for typical message" do
      msg = %{"role" => "user", "parts" => [%{"content" => "hello"}]}
      hash = State.message_hash(msg)

      assert is_binary(hash)
      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end

    test "is stable across calls with same content" do
      msg = %{"role" => "user", "instructions" => "be helpful", "parts" => [%{"content" => "hi"}]}
      hash1 = State.message_hash(msg)
      hash2 = State.message_hash(msg)

      assert hash1 == hash2
    end

    test "differs when role differs" do
      msg1 = %{"role" => "user", "parts" => [%{"content" => "hi"}]}
      msg2 = %{"role" => "assistant", "parts" => [%{"content" => "hi"}]}

      assert State.message_hash(msg1) != State.message_hash(msg2)
    end

    test "differs when instructions differ" do
      msg1 = %{"role" => "user", "instructions" => "be helpful", "parts" => []}
      msg2 = %{"role" => "user", "instructions" => "be concise", "parts" => []}

      assert State.message_hash(msg1) != State.message_hash(msg2)
    end

    test "differs when parts differ" do
      msg1 = %{"role" => "user", "parts" => [%{"content" => "hello"}]}
      msg2 = %{"role" => "user", "parts" => [%{"content" => "world"}]}

      assert State.message_hash(msg1) != State.message_hash(msg2)
    end

    test "handles empty parts list" do
      msg = %{"role" => "user", "parts" => []}
      hash = State.message_hash(msg)

      assert is_binary(hash)
      assert String.length(hash) == 16
    end

    test "handles missing role/instructions fields" do
      msg = %{"parts" => [%{"content" => "data"}]}
      hash = State.message_hash(msg)

      assert is_binary(hash)
      assert String.length(hash) == 16

      # Also works with empty map
      hash2 = State.message_hash(%{})
      assert is_binary(hash2)
      assert String.length(hash2) == 16
    end
  end

  # ── get/set/clear (round-trip) ────────────────────────────────────────

  describe "get/set/clear (round-trip)" do
    test "get_messages on fresh state returns []" do
      {sess, agent} = unique_key()
      assert State.get_messages(sess, agent) == []
    end

    test "set_messages then get_messages round-trips" do
      {sess, agent} = unique_key()
      msgs = [%{"role" => "user", "parts" => [%{"content" => "hi"}]}]

      assert State.set_messages(sess, agent, msgs) == :ok
      assert State.get_messages(sess, agent) == msgs
    end

    test "clear_messages empties state" do
      {sess, agent} = unique_key()
      msgs = [%{"role" => "user", "parts" => [%{"content" => "hi"}]}]

      State.set_messages(sess, agent, msgs)
      assert State.clear_messages(sess, agent) == :ok
      assert State.get_messages(sess, agent) == []
    end

    test "set_messages replaces existing messages (not append)" do
      {sess, agent} = unique_key()

      State.set_messages(sess, agent, [%{"role" => "user", "parts" => [%{"content" => "first"}]}])

      State.set_messages(sess, agent, [%{"role" => "user", "parts" => [%{"content" => "second"}]}])

      assert State.get_messages(sess, agent) == [
               %{"role" => "user", "parts" => [%{"content" => "second"}]}
             ]
    end

    test "set_messages rebuilds hash set (dedup works after set)" do
      {sess, agent} = unique_key()
      msg = %{"role" => "user", "parts" => [%{"content" => "dup"}]}

      State.set_messages(sess, agent, [msg])
      # The same message was set, so appending it should be a no-op (dedup)
      assert State.append_message(sess, agent, msg) == :ok
      assert State.message_count(sess, agent) == 1
    end
  end

  # ── append/extend (dedup) ─────────────────────────────────────────────

  describe "append/extend (dedup)" do
    test "append_message adds to empty state" do
      {sess, agent} = unique_key()
      msg = %{"role" => "user", "parts" => [%{"content" => "hello"}]}

      assert State.append_message(sess, agent, msg) == :ok
      assert State.get_messages(sess, agent) == [msg]
    end

    test "append_message with duplicate hash is a no-op" do
      {sess, agent} = unique_key()
      msg = %{"role" => "user", "parts" => [%{"content" => "same"}]}

      State.append_message(sess, agent, msg)
      State.append_message(sess, agent, msg)

      assert State.get_messages(sess, agent) == [msg]
      assert State.message_count(sess, agent) == 1
    end

    test "extend_messages with all-new messages appends all" do
      {sess, agent} = unique_key()
      msg1 = %{"role" => "user", "parts" => [%{"content" => "first"}]}
      msg2 = %{"role" => "user", "parts" => [%{"content" => "second"}]}

      State.extend_messages(sess, agent, [msg1, msg2])

      assert State.get_messages(sess, agent) == [msg1, msg2]
    end

    test "extend_messages with some duplicates filters them out" do
      {sess, agent} = unique_key()
      msg1 = %{"role" => "user", "parts" => [%{"content" => "keep"}]}
      msg2 = %{"role" => "user", "parts" => [%{"content" => "dup"}]}

      State.append_message(sess, agent, msg1)
      State.extend_messages(sess, agent, [msg1, msg2])

      # msg1 was already present, only msg2 is new
      assert State.get_messages(sess, agent) == [msg1, msg2]
      assert State.message_count(sess, agent) == 2
    end

    test "extend_messages with all duplicates is a no-op" do
      {sess, agent} = unique_key()
      msg = %{"role" => "user", "parts" => [%{"content" => "same"}]}

      State.append_message(sess, agent, msg)
      State.extend_messages(sess, agent, [msg])

      assert State.get_messages(sess, agent) == [msg]
      assert State.message_count(sess, agent) == 1
    end
  end

  # ── message_count/2 ───────────────────────────────────────────────────

  describe "message_count/2" do
    test "zero for fresh state" do
      {sess, agent} = unique_key()
      assert State.message_count(sess, agent) == 0
    end

    test "matches number of unique messages after appends" do
      {sess, agent} = unique_key()
      msg1 = %{"role" => "user", "parts" => [%{"content" => "a"}]}
      msg2 = %{"role" => "user", "parts" => [%{"content" => "b"}]}

      State.append_message(sess, agent, msg1)
      State.append_message(sess, agent, msg2)
      # Duplicate — should not increase count
      State.append_message(sess, agent, msg1)

      assert State.message_count(sess, agent) == 2
    end
  end

  # ── multi-session isolation ───────────────────────────────────────────

  describe "multi-session isolation" do
    test "{sess1, agent} and {sess2, agent} have independent histories" do
      sess1 = "isolation-sess1-#{:rand.uniform(1_000_000)}"
      sess2 = "isolation-sess2-#{:rand.uniform(1_000_000)}"
      agent = "shared-agent"

      msg1 = %{"role" => "user", "parts" => [%{"content" => "for sess1"}]}
      msg2 = %{"role" => "user", "parts" => [%{"content" => "for sess2"}]}

      State.append_message(sess1, agent, msg1)
      State.append_message(sess2, agent, msg2)

      assert State.get_messages(sess1, agent) == [msg1]
      assert State.get_messages(sess2, agent) == [msg2]
    end

    test "{sess, agent1} and {sess, agent2} have independent histories" do
      sess = "shared-session-#{:rand.uniform(1_000_000)}"
      agent1 = "agent-alpha-#{:rand.uniform(1_000_000)}"
      agent2 = "agent-beta-#{:rand.uniform(1_000_000)}"

      msg1 = %{"role" => "user", "parts" => [%{"content" => "for alpha"}]}
      msg2 = %{"role" => "user", "parts" => [%{"content" => "for beta"}]}

      State.append_message(sess, agent1, msg1)
      State.append_message(sess, agent2, msg2)

      assert State.get_messages(sess, agent1) == [msg1]
      assert State.get_messages(sess, agent2) == [msg2]
    end
  end

  # ── inactivity timeout ────────────────────────────────────────────────

  describe "inactivity timeout" do
    test "process exits when inactivity timeout is exceeded" do
      {sess, agent} = unique_key()

      # Use a counter-backed time_fn for deterministic testing
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      time_fn = fn :millisecond ->
        Agent.get(counter, & &1)
      end

      # Start with injectable time_fn
      {:ok, pid} =
        State.start_agent_state(sess, agent, time_fn: time_fn)

      ref = Process.monitor(pid)

      # Advance time past the 30-minute inactivity timeout (1_800_000 ms)
      Agent.update(counter, fn _ -> 1_800_001 end)

      # Trigger the inactivity check manually
      send(pid, :check_inactivity)

      # Process should exit with :normal
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end

    test "process survives when last activity is recent" do
      {sess, agent} = unique_key()

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      time_fn = fn :millisecond ->
        Agent.get(counter, & &1)
      end

      {:ok, pid} =
        State.start_agent_state(sess, agent, time_fn: time_fn)

      ref = Process.monitor(pid)

      # Advance time but not past timeout
      Agent.update(counter, fn _ -> 100_000 end)

      # Touch the state via a mutating operation (this calls touch/1 which updates last_activity)
      msg = %{"role" => "user", "parts" => [%{"content" => "keep-alive"}]}
      State.append_message(sess, agent, msg)

      # Now advance clock to just under timeout from the last activity
      # last_activity was set to 100_000 by the append_message call
      Agent.update(counter, fn _ -> 100_000 + 1_799_999 end)

      # Trigger check — should NOT exit (elapsed = 1_799_999 < 1_800_000)
      send(pid, :check_inactivity)

      # Should NOT receive DOWN — wait briefly and confirm
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200

      # Now advance past timeout
      Agent.update(counter, fn _ -> 100_000 + 1_800_001 end)
      send(pid, :check_inactivity)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp unique_key do
    {"test-#{:rand.uniform(1_000_000)}", "agent-#{:rand.uniform(1_000_000)}"}
  end
end
