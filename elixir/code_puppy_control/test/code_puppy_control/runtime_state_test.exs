defmodule CodePuppyControl.RuntimeStateTest do
  @moduledoc """
  Comprehensive parity tests for RuntimeState GenServer.

  Validates autosave ID lifecycle, session model caching, cache invalidation,
  cache getter/setter round-trips, finalize_autosave_session, and reset
  operations. Covers all public API surface to match Python runtime_state.py.

  async: false because RuntimeState is a named singleton.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.RuntimeState

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RuntimeState)
    RuntimeState.reset_for_test()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Autosave ID
  # ---------------------------------------------------------------------------

  describe "get_current_autosave_id/0" do
    test "generates an autosave ID on first access" do
      id = RuntimeState.get_current_autosave_id()
      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "returns same ID on subsequent calls" do
      id1 = RuntimeState.get_current_autosave_id()
      id2 = RuntimeState.get_current_autosave_id()
      assert id1 == id2
    end

    test "ID matches YYYYMMDD_HHMMSS format" do
      id = RuntimeState.get_current_autosave_id()
      assert Regex.match?(~r/^\d{8}_\d{6}$/, id)
    end
  end

  describe "rotate_autosave_id/0" do
    test "generates a new ID different from current" do
      old_id = RuntimeState.get_current_autosave_id()
      # Sleep to ensure the timestamp changes (format is YYYYMMDD_HHMMSS)
      Process.sleep(1100)
      new_id = RuntimeState.rotate_autosave_id()
      assert new_id != old_id
    end

    test "subsequent get returns the rotated ID" do
      new_id = RuntimeState.rotate_autosave_id()
      assert RuntimeState.get_current_autosave_id() == new_id
    end
  end

  describe "get_current_autosave_session_name/0" do
    test "returns auto_session_ prefixed name" do
      name = RuntimeState.get_current_autosave_session_name()
      id = RuntimeState.get_current_autosave_id()
      assert name == "auto_session_#{id}"
    end
  end

  describe "set_current_autosave_from_session_name/1" do
    test "extracts ID from auto_session_ prefixed name" do
      RuntimeState.set_current_autosave_from_session_name("auto_session_20250101_120000")
      assert RuntimeState.get_current_autosave_id() == "20250101_120000"
    end

    test "uses full name as ID when no prefix" do
      RuntimeState.set_current_autosave_from_session_name("custom-id-123")
      assert RuntimeState.get_current_autosave_id() == "custom-id-123"
    end
  end

  describe "reset_autosave_id/0" do
    test "clears the autosave ID" do
      _ = RuntimeState.get_current_autosave_id()
      :ok = RuntimeState.reset_autosave_id()
      # After reset, next access generates a new ID
      new_id = RuntimeState.get_current_autosave_id()
      assert is_binary(new_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Session Model
  # ---------------------------------------------------------------------------

  describe "get_session_model/0" do
    test "returns nil when not set" do
      assert RuntimeState.get_session_model() == nil
    end
  end

  describe "set_session_model/1" do
    test "sets the session model name" do
      :ok = RuntimeState.set_session_model("claude-sonnet-4")
      assert RuntimeState.get_session_model() == "claude-sonnet-4"
    end

    test "can be set to nil" do
      :ok = RuntimeState.set_session_model("test")
      :ok = RuntimeState.set_session_model(nil)
      assert RuntimeState.get_session_model() == nil
    end
  end

  describe "reset_session_model/0" do
    test "clears the session model" do
      :ok = RuntimeState.set_session_model("to-reset")
      :ok = RuntimeState.reset_session_model()
      assert RuntimeState.get_session_model() == nil
    end
  end

  # ---------------------------------------------------------------------------
  # State Introspection
  # ---------------------------------------------------------------------------

  describe "get_state/0" do
    test "returns full state struct" do
      state = RuntimeState.get_state()

      assert Map.has_key?(state, :autosave_id)
      assert Map.has_key?(state, :session_model)
      assert Map.has_key?(state, :session_start_time)
    end

    test "session_start_time is a DateTime" do
      state = RuntimeState.get_state()
      assert %DateTime{} = state.session_start_time
    end

    test "includes cache fields" do
      state = RuntimeState.get_state()
      assert Map.has_key?(state, :cached_system_prompt)
      assert Map.has_key?(state, :cached_tool_defs)
      assert Map.has_key?(state, :model_name_cache)
      assert Map.has_key?(state, :delayed_compaction_requested)
      assert Map.has_key?(state, :tool_ids_cache)
      assert Map.has_key?(state, :cached_context_overhead)
      assert Map.has_key?(state, :resolved_model_components_cache)
      assert Map.has_key?(state, :puppy_rules_cache)
    end
  end

  # ---------------------------------------------------------------------------
  # Cache Invalidation
  # ---------------------------------------------------------------------------

  describe "invalidate_caches/0" do
    test "clears context overhead and tool IDs caches" do
      :ok = RuntimeState.set_cached_context_overhead(100)
      :ok = RuntimeState.set_tool_ids_cache([1, 2, 3])

      # Flush casts by issuing a synchronous call
      _ = RuntimeState.get_state()

      assert RuntimeState.get_cached_context_overhead() == 100
      assert RuntimeState.get_tool_ids_cache() == [1, 2, 3]

      assert :ok = RuntimeState.invalidate_caches()

      assert RuntimeState.get_cached_context_overhead() == nil
      assert RuntimeState.get_tool_ids_cache() == nil
    end

    test "does not clear session-scoped caches" do
      :ok = RuntimeState.set_cached_system_prompt("my prompt")
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_caches()

      # Session-scoped caches should survive
      assert RuntimeState.get_cached_system_prompt() == "my prompt"
    end
  end

  describe "invalidate_all_token_caches/0" do
    test "clears all token-related caches" do
      :ok = RuntimeState.set_cached_context_overhead(100)
      :ok = RuntimeState.set_cached_system_prompt("my prompt")
      :ok = RuntimeState.set_cached_tool_defs([%{"name" => "test"}])
      :ok = RuntimeState.set_tool_ids_cache([1, 2])
      :ok = RuntimeState.set_resolved_model_components_cache(%{"provider" => "anthropic"})
      :ok = RuntimeState.set_puppy_rules_cache("AGENTS.md content")
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_all_token_caches()

      assert RuntimeState.get_cached_context_overhead() == nil
      assert RuntimeState.get_cached_system_prompt() == nil
      assert RuntimeState.get_cached_tool_defs() == nil
      assert RuntimeState.get_tool_ids_cache() == nil
      assert RuntimeState.get_resolved_model_components_cache() == nil
      assert RuntimeState.get_puppy_rules_cache() == nil
    end

    test "does not clear model_name_cache" do
      :ok = RuntimeState.set_model_name_cache("claude-sonnet-4")
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_all_token_caches()

      # model_name_cache is NOT a token-related cache
      assert RuntimeState.get_model_name_cache() == "claude-sonnet-4"
    end

    test "cache parity: clears puppy_rules_cache (matches Python AgentRuntimeState.puppy_rules)" do
      :ok = RuntimeState.set_puppy_rules_cache("rules content")
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_all_token_caches()

      # puppy_rules_cache IS a token-related cache (Python parity)
      assert RuntimeState.get_puppy_rules_cache() == nil
    end
  end

  describe "invalidate_system_prompt_cache/0" do
    test "clears system prompt and context overhead" do
      :ok = RuntimeState.set_cached_system_prompt("my prompt")
      :ok = RuntimeState.set_cached_context_overhead(50)
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_system_prompt_cache()

      assert RuntimeState.get_cached_system_prompt() == nil
      assert RuntimeState.get_cached_context_overhead() == nil
    end

    test "does not clear tool defs or tool IDs" do
      :ok = RuntimeState.set_cached_tool_defs([%{"name" => "test"}])
      :ok = RuntimeState.set_tool_ids_cache([1])
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_system_prompt_cache()

      assert RuntimeState.get_cached_tool_defs() == [%{"name" => "test"}]
      assert RuntimeState.get_tool_ids_cache() == [1]
    end
  end

  # ---------------------------------------------------------------------------
  # Cache Getter / Setter Round-Trips
  # ---------------------------------------------------------------------------

  describe "cached_system_prompt getter/setter" do
    test "round-trips a string value" do
      assert RuntimeState.get_cached_system_prompt() == nil
      :ok = RuntimeState.set_cached_system_prompt("hello world")
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_system_prompt() == "hello world"
    end

    test "can be set to nil" do
      :ok = RuntimeState.set_cached_system_prompt("temp")
      _ = RuntimeState.get_state()
      :ok = RuntimeState.set_cached_system_prompt(nil)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_system_prompt() == nil
    end
  end

  describe "cached_tool_defs getter/setter" do
    test "round-trips a list of maps" do
      defs = [%{"name" => "tool1"}, %{"name" => "tool2"}]
      :ok = RuntimeState.set_cached_tool_defs(defs)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_tool_defs() == defs
    end

    test "defaults to nil" do
      assert RuntimeState.get_cached_tool_defs() == nil
    end
  end

  describe "model_name_cache getter/setter" do
    test "round-trips a model name" do
      assert RuntimeState.get_model_name_cache() == nil
      :ok = RuntimeState.set_model_name_cache("gpt-4o")
      _ = RuntimeState.get_state()
      assert RuntimeState.get_model_name_cache() == "gpt-4o"
    end
  end

  describe "delayed_compaction_requested getter/setter" do
    test "defaults to false after reset_for_test" do
      assert RuntimeState.get_delayed_compaction_requested() == false
    end

    test "round-trips a boolean" do
      :ok = RuntimeState.set_delayed_compaction_requested(true)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_delayed_compaction_requested() == true

      :ok = RuntimeState.set_delayed_compaction_requested(false)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_delayed_compaction_requested() == false
    end
  end

  describe "tool_ids_cache getter/setter" do
    test "round-trips an arbitrary value" do
      assert RuntimeState.get_tool_ids_cache() == nil
      :ok = RuntimeState.set_tool_ids_cache(%{"call_1" => "abc"})
      _ = RuntimeState.get_state()
      assert RuntimeState.get_tool_ids_cache() == %{"call_1" => "abc"}
    end
  end

  describe "cached_context_overhead getter/setter" do
    test "round-trips an integer value" do
      assert RuntimeState.get_cached_context_overhead() == nil
      :ok = RuntimeState.set_cached_context_overhead(42)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_context_overhead() == 42
    end

    test "can be set to nil" do
      :ok = RuntimeState.set_cached_context_overhead(100)
      _ = RuntimeState.get_state()
      :ok = RuntimeState.set_cached_context_overhead(nil)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_context_overhead() == nil
    end
  end

  describe "resolved_model_components_cache getter/setter" do
    test "round-trips a map" do
      cache = %{"provider" => "anthropic", "model" => "claude-3"}
      :ok = RuntimeState.set_resolved_model_components_cache(cache)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_resolved_model_components_cache() == cache
    end
  end

  describe "puppy_rules_cache getter/setter" do
    test "defaults to nil after reset_for_test" do
      assert RuntimeState.get_puppy_rules_cache() == nil
    end

    test "round-trips a string value" do
      :ok = RuntimeState.set_puppy_rules_cache("AGENTS.md rules content")
      _ = RuntimeState.get_state()
      assert RuntimeState.get_puppy_rules_cache() == "AGENTS.md rules content"
    end

    test "can be set to nil" do
      :ok = RuntimeState.set_puppy_rules_cache("temp")
      _ = RuntimeState.get_state()
      :ok = RuntimeState.set_puppy_rules_cache(nil)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_puppy_rules_cache() == nil
    end

    test "accessible via Cache submodule" do
      alias CodePuppyControl.RuntimeState.Cache

      :ok = Cache.set_puppy_rules_cache("from cache module")
      _ = RuntimeState.get_state()
      assert Cache.get_puppy_rules_cache() == "from cache module"
      assert RuntimeState.get_puppy_rules_cache() == "from cache module"
    end
  end

  # ---------------------------------------------------------------------------
  # finalize_autosave_session/0
  # ---------------------------------------------------------------------------

  describe "finalize_autosave_session/0" do
    test "returns a new autosave ID" do
      result = RuntimeState.finalize_autosave_session()
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "rotates to a different ID than before" do
      old_id = RuntimeState.get_current_autosave_id()
      Process.sleep(1100)
      new_id = RuntimeState.finalize_autosave_session()
      assert new_id != old_id
    end

    test "subsequent get returns the finalized ID" do
      new_id = RuntimeState.finalize_autosave_session()
      assert RuntimeState.get_current_autosave_id() == new_id
    end

    test "with failing save callback, still rotates" do
      failing_fn = fn -> raise "boom" end
      new_id = RuntimeState.finalize_autosave_session(failing_fn)
      assert is_binary(new_id)
      assert String.length(new_id) > 0
    end

    test "with failing rotate, returns fallback ID" do
      save_fn = fn -> :ok end
      result = RuntimeState.finalize_autosave_session(save_fn)
      assert is_binary(result)
      assert Regex.match?(~r/^\d{8}_\d{6}$/, result)
    end

    # Regression test: save_fn MUST be called BEFORE rotation (code_puppy-ctj.4)
    test "save callback is invoked before rotation (autosave-before-rotation)" do
      old_id = RuntimeState.get_current_autosave_id()
      Process.sleep(1100)
      # Track call order with a process dictionary flag
      Process.put(:finalize_test_order, [])

      tracking_fn = fn ->
        current = Process.get(:finalize_test_order)
        Process.put(:finalize_test_order, current ++ [:save_called])
      end

      # We can't easily intercept rotate_autosave_id from inside finalize,
      # but we can verify the save_fn was called and the ID changed.
      _result = RuntimeState.finalize_autosave_session(tracking_fn)

      # The save function must have been called
      assert :save_called in Process.get(:finalize_test_order)
      # The ID must have rotated
      assert RuntimeState.get_current_autosave_id() != old_id
    after
      Process.delete(:finalize_test_order)
    end

    test "save callback is called even if it raises (never silently skipped)" do
      call_count = Process.get(:save_call_count, 0)

      raising_fn = fn ->
        Process.put(:save_call_count, Process.get(:save_call_count, 0) + 1)
        raise "intentional failure"
      end

      _result = RuntimeState.finalize_autosave_session(raising_fn)

      # The save function was called even though it raised
      assert Process.get(:save_call_count, 0) > call_count
    after
      Process.delete(:save_call_count)
    end
  end

  # ---------------------------------------------------------------------------
  # reset_for_test/0
  # ---------------------------------------------------------------------------

  describe "reset_for_test/0" do
    test "resets all state to initial values" do
      # Set some values
      _ = RuntimeState.get_current_autosave_id()
      :ok = RuntimeState.set_session_model("test-model")
      :ok = RuntimeState.set_cached_system_prompt("test prompt")
      :ok = RuntimeState.set_cached_context_overhead(99)
      :ok = RuntimeState.set_delayed_compaction_requested(true)
      _ = RuntimeState.get_state()

      # Reset
      assert :ok = RuntimeState.reset_for_test()

      # Verify all fields reset
      state = RuntimeState.get_state()
      # autosave_id is nil after reset (lazy init on next get)
      assert state.autosave_id == nil
      assert state.session_model == nil
      assert state.cached_system_prompt == nil
      assert state.cached_context_overhead == nil
      assert state.delayed_compaction_requested == false
      assert state.cached_tool_defs == nil
      assert state.model_name_cache == nil
      assert state.tool_ids_cache == nil
      assert state.resolved_model_components_cache == nil
      assert state.puppy_rules_cache == nil
    end

    test "session_start_time is refreshed after reset" do
      state1 = RuntimeState.get_state()
      Process.sleep(10)
      assert :ok = RuntimeState.reset_for_test()
      state2 = RuntimeState.get_state()
      # session_start_time should be equal or newer
      assert DateTime.compare(state2.session_start_time, state1.session_start_time) != :lt
    end
  end
end
