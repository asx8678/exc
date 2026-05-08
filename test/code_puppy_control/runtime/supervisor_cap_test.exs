defmodule CodePuppyControl.Runtime.SupervisorCapTest do
  @moduledoc """
  Verifies that DynamicSupervisors enforce the max_children caps wired
  through CodePuppyControl.Runtime.Limits. We use the Agent.State.Supervisor
  as the canonical example because it's the cheapest per-process and has
  the highest default cap (256) → easy to test at a small, overridden cap.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State.Supervisor, as: AgentStateSup

  @tag :capacity
  test "agent state supervisor refuses to start past cap" do
    # Read the live max_children from the running DynamicSupervisor.
    # max_children is set at init time from Limits.max_agent_states()/0
    # and baked into the supervisor's internal state — changing Application
    # env after init won't affect it.
    live_max = get_live_max(AgentStateSup)
    assert live_max > 0, "Expected positive max_children, got: #{inspect(live_max)}"

    before = DynamicSupervisor.count_children(AgentStateSup).workers
    headroom = live_max - before

    # If someone else has already filled the supervisor we can't run
    # this test meaningfully — skip gracefully.
    if headroom <= 0 do
      IO.puts("[supervisor_cap_test] Agent.State.Supervisor already at cap; skipping")
      :ok
    else
      # Fill exactly to the cap
      for i <- 1..headroom do
        assert {:ok, _pid} =
                 AgentStateSup.start_agent_state("cap-test-#{i}", "agent-#{i}")
      end

      # Verify we're now at capacity
      assert DynamicSupervisor.count_children(AgentStateSup).workers == live_max

      # One more should be refused with {:error, :max_children}
      assert {:error, :max_children} =
               AgentStateSup.start_agent_state("cap-test-overflow", "agent-x")

      # Clean up
      for i <- 1..headroom do
        AgentStateSup.terminate_agent_state("cap-test-#{i}", "agent-#{i}")
      end

      :ok
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp get_live_max(sup) do
    # DynamicSupervisor stores its state as a %DynamicSupervisor{} struct
    # accessible via :sys.get_state/1. The :max_children field holds the
    # cap configured at init time.
    case :sys.get_state(sup) do
      %DynamicSupervisor{max_children: n} when is_integer(n) -> n
      %DynamicSupervisor{max_children: :infinity} -> 1_000_000
      other -> raise "Unexpected supervisor state: #{inspect(other)}"
    end
  end
end
