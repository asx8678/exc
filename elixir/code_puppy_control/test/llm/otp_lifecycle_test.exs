defmodule CodePuppyControl.LLM.OtpLifecycleTest do
  @moduledoc """
  OTP lifecycle and restart behavior tests for LLM GenServers.

  Verifies supervisor restart, state recovery/reset, ETS recreation,
  concurrent access during restart, and unexpected message resilience.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import CodePuppyControl.TestSupport.OtpLifecycleHelpers

  alias CodePuppyControl.RoundRobinModel
  alias CodePuppyControl.ModelAvailability
  alias CodePuppyControl.ModelRegistry

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # ── RoundRobinModel Restart Behavior ─────────────────────────────────────

  describe "RoundRobinModel restart behavior" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
      :ok
    end

    test "supervisor restarts killed RoundRobinModel" do
      kill_and_restart(RoundRobinModel, :round_robin_state)
    end

    test "ETS table is recreated after restart" do
      :ok = RoundRobinModel.configure(models: ["alpha", "beta"], rotate_every: 2)
      assert :ets.whereis(:round_robin_state) != :undefined

      kill_and_restart(RoundRobinModel, :round_robin_state)

      assert :ets.whereis(:round_robin_state) != :undefined,
             "ETS table :round_robin_state should be recreated after restart"
    end

    test "state is reset after restart (no persistent state recovery)" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2"], rotate_every: 1)
      assert RoundRobinModel.advance_and_get() == "m1"
      assert RoundRobinModel.get_current_model() == "m2"

      kill_and_restart(RoundRobinModel, :round_robin_state)

      state = RoundRobinModel.get_state()
      assert state != nil, "State should exist after restart (ETS recreated in init)"
      assert state.current_index == 0
      assert state.request_count == 0
    end

    test "callers racing restart either exit or recover cleanly" do
      :ok = RoundRobinModel.configure(models: ["a", "b"], rotate_every: 1)
      kill_only(RoundRobinModel)

      # GenServer.call should raise exit — callers catch it gracefully.
      # Note: the supervisor may restart the process before all calls are made,
      # so some calls may succeed against the new instance. Both outcomes are valid.
      results =
        for _i <- 1..5 do
          try do
            RoundRobinModel.advance_and_get()
          catch
            :exit, _ -> :exit_caught
          end
        end

      valid_results = [:exit_caught, nil]

      for result <- results do
        assert result in valid_results,
               "Result during restart race should be an exit or nil, got: #{inspect(result)}"
      end

      # Verify recovery
      wait_for_restart(RoundRobinModel, :round_robin_state)
      :ok = RoundRobinModel.configure(models: ["recovered"], rotate_every: 1)
      assert RoundRobinModel.advance_and_get() == "recovered"
      flush_exits()
    end

    test "concurrent callers during restart window don't crash" do
      :ok = RoundRobinModel.configure(models: ["x", "y"], rotate_every: 1)

      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            Process.flag(:trap_exit, true)
            Process.sleep(:rand.uniform(20))

            try do
              RoundRobinModel.advance_and_get()
            catch
              :exit, _ -> :retry_later
            end
          end)
        end

      kill_process(RoundRobinModel)
      wait_for_restart(RoundRobinModel, :round_robin_state)
      :ok = RoundRobinModel.configure(models: ["x", "y"], rotate_every: 1)

      for {_task, result} <- yield_and_collect(tasks, 10_000) do
        case result do
          {:ok, val} when is_binary(val) -> :ok
          {:ok, nil} -> :ok
          {:ok, :retry_later} -> :ok
          {:exit, :timeout} -> flunk("task timed out during restart race: #{inspect(result)}")
          {:exit, _} -> :ok
          other -> flunk("unexpected task result during restart race: #{inspect(other)}")
        end
      end

      assert RoundRobinModel.advance_and_get() in ["x", "y"]
      flush_exits()
    end

    test "configure works after restart" do
      :ok = RoundRobinModel.configure(models: ["pre-kill"], rotate_every: 1)
      kill_and_restart(RoundRobinModel, :round_robin_state)

      :ok = RoundRobinModel.configure(models: ["post-kill-a", "post-kill-b"], rotate_every: 3)
      assert RoundRobinModel.get_state().models == ["post-kill-a", "post-kill-b"]
      assert RoundRobinModel.get_state().rotate_every == 3
    end
  end

  # ── ModelAvailability Restart Behavior ───────────────────────────────────

  describe "ModelAvailability restart behavior" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelAvailability)
      ModelAvailability.reset_all()
      :ok
    end

    test "supervisor restarts killed ModelAvailability" do
      kill_and_restart(ModelAvailability, :model_health)
    end

    test "ETS health table is recreated after restart" do
      ModelAvailability.mark_terminal("test-model", :quota)
      assert :ets.whereis(:model_health) != :undefined

      kill_and_restart(ModelAvailability, :model_health)

      assert :ets.whereis(:model_health) != :undefined,
             "ETS table :model_health should be recreated after restart"
    end

    test "ETS last_resort table is recreated after restart" do
      ModelAvailability.mark_as_last_resort("fallback-model", true)
      assert :ets.whereis(:model_last_resort) != :undefined

      kill_and_restart(ModelAvailability, :model_last_resort)

      assert :ets.whereis(:model_last_resort) != :undefined,
             "ETS table :model_last_resort should be recreated after restart"
    end

    test "health state is cleared after restart (fresh init)" do
      ModelAvailability.mark_terminal("doomed", :quota)
      ModelAvailability.mark_sticky_retry("sticky")
      ModelAvailability.consume_sticky_attempt("sticky")

      assert ModelAvailability.snapshot("doomed").available == false
      assert ModelAvailability.snapshot("sticky").available == false

      kill_and_restart(ModelAvailability, :model_health)

      assert ModelAvailability.snapshot("doomed").available == true,
             "Terminal state should be cleared after restart"

      assert ModelAvailability.snapshot("sticky").available == true,
             "Sticky state should be cleared after restart"
    end

    test "last-resort flags are cleared after restart" do
      ModelAvailability.mark_as_last_resort("fallback", true)
      assert ModelAvailability.is_last_resort("fallback") == true

      kill_and_restart(ModelAvailability, :model_last_resort)

      assert ModelAvailability.is_last_resort("fallback") == false,
             "Last-resort flags should be cleared after restart"
    end

    test "ETS reads during restart window may see missing table or recovered state" do
      ModelAvailability.mark_terminal("going-away", :quota)
      kill_only(ModelAvailability)

      results =
        for _i <- 1..5 do
          try do
            ModelAvailability.snapshot("going-away")
          rescue
            ArgumentError -> :table_gone
          catch
            :exit, _ -> :exit_caught
          end
        end

      valid = [
        :table_gone,
        :exit_caught,
        %{available: true, reason: nil},
        %{available: false, reason: :quota}
      ]

      for result <- results do
        assert result in valid,
               "Snapshot during dead window should handle missing ETS table gracefully"
      end

      wait_for_restart(ModelAvailability, :model_health)
      assert ModelAvailability.snapshot("going-away").available == true
      flush_exits()
    end

    test "select_first_available may race restart before recovering" do
      ModelAvailability.mark_terminal("dead-model", :quota)
      kill_only(ModelAvailability)

      try do
        result = ModelAvailability.select_first_available(["dead-model", "alive-model"])
        assert is_map(result)
      rescue
        ArgumentError -> :ok
      end

      wait_for_restart(ModelAvailability, :model_health)
      result = ModelAvailability.select_first_available(["any-model"])
      assert is_map(result)
      flush_exits()
    end

    test "concurrent mark_healthy/mark_terminal during restart window" do
      ModelAvailability.mark_terminal("concurrent-test", :quota)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Process.flag(:trap_exit, true)
            Process.sleep(:rand.uniform(10))

            try do
              if rem(i, 2) == 0,
                do: ModelAvailability.mark_healthy("concurrent-test"),
                else: ModelAvailability.mark_terminal("concurrent-test", :capacity)
            catch
              :exit, _ -> :no_reply
            end
          end)
        end

      kill_process(ModelAvailability)
      wait_for_restart(ModelAvailability, :model_health)

      ModelAvailability.mark_terminal("post-restart", :quota)
      assert ModelAvailability.snapshot("post-restart").available == false

      for {_task, result} <- yield_and_collect(tasks, 10_000) do
        case result do
          {:ok, :ok} ->
            :ok

          {:ok, :no_reply} ->
            :ok

          {:exit, :noproc} ->
            :ok

          {:exit, :timeout} ->
            flunk("task timed out during ModelAvailability restart: #{inspect(result)}")

          other ->
            flunk("unexpected ModelAvailability task result: #{inspect(other)}")
        end
      end

      flush_exits()
    end
  end

  # ── ModelRegistry Restart Behavior ───────────────────────────────────────

  describe "ModelRegistry restart behavior" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)
      :ok
    end

    test "supervisor restarts killed ModelRegistry" do
      kill_and_restart(ModelRegistry, :model_configs)
    end

    test "ETS table is recreated after restart" do
      assert :ets.whereis(:model_configs) != :undefined

      kill_and_restart(ModelRegistry, :model_configs)

      assert :ets.whereis(:model_configs) != :undefined,
             "ETS table :model_configs should be recreated after restart"
    end

    test "config is reloaded from disk after restart" do
      all_before = ModelRegistry.get_all_configs()
      assert map_size(all_before) > 0

      kill_and_restart(ModelRegistry, :model_configs)

      all_after = ModelRegistry.get_all_configs()
      assert map_size(all_after) > 0

      for {name, _config} <- all_before do
        assert Map.has_key?(all_after, name),
               "Model '#{name}' should be present after config reload"
      end
    end

    test "injected ETS entries are lost after restart (config reload is authoritative)" do
      :ets.insert(:model_configs, {"injected-model", %{"type" => "openai", "name" => "injected"}})
      assert ModelRegistry.get_config("injected-model") != nil

      kill_and_restart(ModelRegistry, :model_configs)

      assert ModelRegistry.get_config("injected-model") == nil,
             "Injected models should not survive restart"
    end

    test "ETS reads during restart window may see missing table or recovered state" do
      kill_only(ModelRegistry)

      results =
        for _i <- 1..5 do
          try do
            ModelRegistry.get_config("some-model")
          rescue
            ArgumentError -> :table_gone
          catch
            :exit, _ -> :exit_caught
          end
        end

      # The supervisor may restart quickly enough for reads to hit the recovered
      # registry.  Depending on prior test order, recovered state may include a
      # matching config map, so accept both transient failure modes and a
      # successful recovered read. (code_puppy-i1n)
      for r <- results, do: assert(r in [:table_gone, :exit_caught, nil] or is_map(r))

      wait_for_restart(ModelRegistry, :model_configs)
      assert map_size(ModelRegistry.get_all_configs()) > 0
      flush_exits()
    end

    test "list_model_names may race restart before recovering" do
      kill_only(ModelRegistry)

      try do
        ModelRegistry.list_model_names()
      rescue
        ArgumentError -> :ok
      end

      wait_for_restart(ModelRegistry, :model_configs)
      assert is_list(ModelRegistry.list_model_names())
      flush_exits()
    end

    test "concurrent reads during reload window" do
      tasks =
        for _i <- 1..15 do
          Task.async(fn ->
            Process.flag(:trap_exit, true)
            Process.sleep(:rand.uniform(10))

            try do
              ModelRegistry.get_all_configs()
            catch
              :exit, _ -> :no_reply
            end
          end)
        end

      kill_process(ModelRegistry)
      wait_for_restart(ModelRegistry, :model_configs)

      for {_t, r} <- yield_and_collect(tasks, 10_000) do
        case r do
          {:ok, %{}} ->
            :ok

          {:ok, :no_reply} ->
            :ok

          {:exit, :timeout} ->
            flunk("task timed out during ModelRegistry reload race: #{inspect(r)}")

          {:exit, _} ->
            :ok

          other ->
            flunk("unexpected result: #{inspect(other)}")
        end
      end

      assert map_size(ModelRegistry.get_all_configs()) > 0
      flush_exits()
    end

    test "reload after restart produces same models" do
      kill_and_restart(ModelRegistry, :model_configs)
      assert :ok = ModelRegistry.reload()
      assert map_size(ModelRegistry.get_all_configs()) > 0
    end
  end

  # ── Concurrent Access During Restart ─────────────────────────────────────

  describe "concurrent access during restart" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelAvailability)
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)
      ModelAvailability.reset_all()
      :ok
    end

    test "mid-flight advance_and_get isolates worker exits without wedging recovery" do
      :ok = RoundRobinModel.configure(models: ["p", "q", "r"], rotate_every: 1)

      {successes, errors} =
        spawn_workers_and_kill(10, 20, RoundRobinModel, fn ->
          RoundRobinModel.advance_and_get()
        end)

      wait_for_restart(RoundRobinModel, :round_robin_state)
      :ok = RoundRobinModel.configure(models: ["p", "q", "r"], rotate_every: 1)

      assert successes > 0, "At least one worker call should succeed across the restart race"
      assert successes + errors > 0, "Workers should have attempted some calls"
      assert RoundRobinModel.advance_and_get() in ["p", "q", "r"]
      flush_exits()
    end

    test "mid-flight ModelAvailability mutations keep making forward progress" do
      ModelAvailability.mark_terminal("dead-1", :quota)
      ModelAvailability.mark_sticky_retry("sticky-1")

      {successes, _errors} =
        spawn_workers_and_kill(8, 15, ModelAvailability, fn ->
          case :rand.uniform(3) do
            1 -> ModelAvailability.mark_healthy("dead-1")
            2 -> ModelAvailability.mark_terminal("dead-1", :capacity)
            3 -> ModelAvailability.consume_sticky_attempt("sticky-1")
          end
        end)

      wait_for_restart(ModelAvailability, :model_health)

      assert successes > 0,
             "At least one ModelAvailability mutation should succeed across the restart race"

      ModelAvailability.mark_terminal("post-chaos", :quota)
      assert ModelAvailability.snapshot("post-chaos").available == false
      flush_exits()
    end

    test "mid-flight ETS reads surface restarts without wedging recovery" do
      {successes, errors} =
        spawn_workers_and_kill(6, 15, ModelRegistry, fn ->
          try do
            ModelRegistry.get_all_configs()
          rescue
            ArgumentError -> nil
          end
        end)

      wait_for_restart(ModelRegistry, :model_configs)

      assert successes > 0,
             "At least one ModelRegistry read should succeed across the restart race"

      assert successes + errors > 0
      assert is_map(ModelRegistry.get_all_configs())
      flush_exits()
    end
  end

  # ── Unexpected Message Handling ──────────────────────────────────────────

  describe "unexpected message handling" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelAvailability)
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)
      ModelAvailability.reset_all()
      :ok
    end

    test "RoundRobinModel ignores garbage messages without crashing" do
      :ok = RoundRobinModel.configure(models: ["stable-a", "stable-b"], rotate_every: 1)
      pid_before = Process.whereis(RoundRobinModel)

      capture_log(fn ->
        send(RoundRobinModel, :garbage_atom)
        send(RoundRobinModel, {:tuple, "with", 123})
        send(RoundRobinModel, "just a string")
        send(RoundRobinModel, [1, 2, 3])
        send(RoundRobinModel, nil)
        Process.sleep(50)
      end)

      assert Process.whereis(RoundRobinModel) == pid_before
      assert Process.alive?(pid_before)
      assert RoundRobinModel.advance_and_get() == "stable-a"
      assert RoundRobinModel.advance_and_get() == "stable-b"
    end

    test "ModelAvailability ignores garbage messages without crashing" do
      ModelAvailability.mark_terminal("pre-garbage", :quota)
      pid_before = Process.whereis(ModelAvailability)

      capture_log(fn ->
        send(ModelAvailability, :nonsense)
        send(ModelAvailability, {:weird, %{nested: true}})
        send(ModelAvailability, [1, :two, "three"])
        send(ModelAvailability, 42)
        send(ModelAvailability, nil)
        Process.sleep(50)
      end)

      assert Process.whereis(ModelAvailability) == pid_before
      assert Process.alive?(pid_before)
      assert ModelAvailability.snapshot("pre-garbage").available == false
      assert ModelAvailability.snapshot("pre-garbage").reason == :quota
    end

    test "ModelRegistry ignores garbage messages without crashing" do
      all_before = ModelRegistry.get_all_configs()
      pid_before = Process.whereis(ModelRegistry)

      capture_log(fn ->
        send(ModelRegistry, :unexpected_atom)
        send(ModelRegistry, {:strange, "message", %{data: 42}})
        send(ModelRegistry, "random string")
        send(ModelRegistry, %{a: :map})
        send(ModelRegistry, nil)
        Process.sleep(50)
      end)

      assert Process.whereis(ModelRegistry) == pid_before
      assert Process.alive?(pid_before)

      all_after = ModelRegistry.get_all_configs()
      assert map_size(all_after) == map_size(all_before)

      for {name, config} <- all_before do
        assert Map.get(all_after, name) == config
      end
    end

    test "rapid garbage messages don't corrupt state" do
      :ok = RoundRobinModel.configure(models: ["spam-test"], rotate_every: 1)
      ModelAvailability.mark_terminal("spam-health", :capacity)
      ModelAvailability.mark_as_last_resort("spam-fallback", true)

      rr_pid = Process.whereis(RoundRobinModel)
      ma_pid = Process.whereis(ModelAvailability)

      capture_log(fn ->
        for _i <- 1..100 do
          send(RoundRobinModel, {:spam, :msg, :rand.uniform(1000)})
          send(ModelAvailability, {:spam, :msg, :rand.uniform(1000)})
          send(ModelRegistry, {:spam, :msg, :rand.uniform(1000)})
        end

        Process.sleep(200)
      end)

      # All processes alive with same PIDs
      assert Process.whereis(RoundRobinModel) == rr_pid
      assert Process.whereis(ModelAvailability) == ma_pid
      assert Process.alive?(Process.whereis(ModelRegistry))

      # State intact
      assert RoundRobinModel.advance_and_get() == "spam-test"
      assert ModelAvailability.snapshot("spam-health").available == false
      assert ModelAvailability.is_last_resort("spam-fallback") == true
    end
  end

  # ── Cross-Process Resilience ─────────────────────────────────────────────

  describe "cross-process resilience" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelAvailability)
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelRegistry)
      ModelAvailability.reset_all()
      :ok
    end

    test "killing RoundRobinModel doesn't affect ModelAvailability" do
      ModelAvailability.mark_terminal("unrelated-model", :quota)
      kill_and_restart(RoundRobinModel, :round_robin_state)
      assert ModelAvailability.snapshot("unrelated-model").available == false
    end

    test "killing ModelAvailability doesn't affect RoundRobinModel" do
      :ok = RoundRobinModel.configure(models: ["survivor"], rotate_every: 1)
      assert RoundRobinModel.advance_and_get() == "survivor"
      kill_and_restart(ModelAvailability, :model_health)
      assert RoundRobinModel.get_current_model() == "survivor"
    end

    test "killing ModelRegistry doesn't affect others" do
      :ok = RoundRobinModel.configure(models: ["rr-model"], rotate_every: 1)
      ModelAvailability.mark_terminal("ma-model", :quota)
      kill_and_restart(ModelRegistry, :model_configs)
      assert RoundRobinModel.advance_and_get() == "rr-model"
      assert ModelAvailability.snapshot("ma-model").available == false
    end

    test "killing one GenServer doesn't cascade (one_for_one)" do
      rr_pid = Process.whereis(RoundRobinModel)
      ma_pid = Process.whereis(ModelAvailability)
      mr_pid = Process.whereis(ModelRegistry)

      kill_and_restart(ModelAvailability, :model_health)

      assert Process.whereis(RoundRobinModel) == rr_pid,
             "RoundRobinModel should not be affected (one_for_one)"

      assert Process.whereis(ModelRegistry) == mr_pid,
             "ModelRegistry should not be affected (one_for_one)"

      assert Process.whereis(ModelAvailability) != ma_pid
      flush_exits()
    end
  end
end
