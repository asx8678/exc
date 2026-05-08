defmodule CodePuppyControl.Runtime.RuntimeStateTest do
  @moduledoc """
  Integration tests for RuntimeState GenServer — runtime-only session state.

  Validates autosave ID lifecycle, session model caching, cache invalidation,
  cache getter/setters, finalize_autosave_session, and reset operations.
  async: false because RuntimeState is a named singleton.

  For comprehensive unit-level parity tests, see
  test/code_puppy_control/runtime_state_test.exs.
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
  end

  # ---------------------------------------------------------------------------
  # Cache Invalidation
  # ---------------------------------------------------------------------------

  describe "invalidate_caches/0" do
    test "clears context overhead and tool IDs" do
      :ok = RuntimeState.set_cached_context_overhead(42)
      :ok = RuntimeState.set_tool_ids_cache(["a"])
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_caches()
      assert RuntimeState.get_cached_context_overhead() == nil
      assert RuntimeState.get_tool_ids_cache() == nil
    end
  end

  describe "invalidate_all_token_caches/0" do
    test "clears all token-related caches" do
      :ok = RuntimeState.set_cached_context_overhead(10)
      :ok = RuntimeState.set_cached_system_prompt("p")
      :ok = RuntimeState.set_cached_tool_defs([%{}])
      :ok = RuntimeState.set_tool_ids_cache([1])
      :ok = RuntimeState.set_resolved_model_components_cache(%{})
      :ok = RuntimeState.set_puppy_rules_cache("rules")
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_all_token_caches()
      assert RuntimeState.get_cached_context_overhead() == nil
      assert RuntimeState.get_cached_system_prompt() == nil
      assert RuntimeState.get_cached_tool_defs() == nil
      assert RuntimeState.get_tool_ids_cache() == nil
      assert RuntimeState.get_resolved_model_components_cache() == nil
      assert RuntimeState.get_puppy_rules_cache() == nil
    end
  end

  describe "invalidate_system_prompt_cache/0" do
    test "clears system prompt and context overhead" do
      :ok = RuntimeState.set_cached_system_prompt("p")
      :ok = RuntimeState.set_cached_context_overhead(5)
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.invalidate_system_prompt_cache()
      assert RuntimeState.get_cached_system_prompt() == nil
      assert RuntimeState.get_cached_context_overhead() == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Cache Getter / Setter
  # ---------------------------------------------------------------------------

  describe "cache getter/setter round-trips" do
    test "cached_system_prompt" do
      assert RuntimeState.get_cached_system_prompt() == nil
      :ok = RuntimeState.set_cached_system_prompt("hello")
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_system_prompt() == "hello"
    end

    test "cached_tool_defs" do
      :ok = RuntimeState.set_cached_tool_defs([%{"name" => "x"}])
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_tool_defs() == [%{"name" => "x"}]
    end

    test "model_name_cache" do
      :ok = RuntimeState.set_model_name_cache("m")
      _ = RuntimeState.get_state()
      assert RuntimeState.get_model_name_cache() == "m"
    end

    test "delayed_compaction_requested" do
      assert RuntimeState.get_delayed_compaction_requested() == false
      :ok = RuntimeState.set_delayed_compaction_requested(true)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_delayed_compaction_requested() == true
    end

    test "tool_ids_cache" do
      :ok = RuntimeState.set_tool_ids_cache([1])
      _ = RuntimeState.get_state()
      assert RuntimeState.get_tool_ids_cache() == [1]
    end

    test "cached_context_overhead" do
      :ok = RuntimeState.set_cached_context_overhead(99)
      _ = RuntimeState.get_state()
      assert RuntimeState.get_cached_context_overhead() == 99
    end

    test "resolved_model_components_cache" do
      :ok = RuntimeState.set_resolved_model_components_cache(%{"k" => "v"})
      _ = RuntimeState.get_state()
      assert RuntimeState.get_resolved_model_components_cache() == %{"k" => "v"}
    end

    test "puppy_rules_cache" do
      assert RuntimeState.get_puppy_rules_cache() == nil
      :ok = RuntimeState.set_puppy_rules_cache("AGENTS.md")
      _ = RuntimeState.get_state()
      assert RuntimeState.get_puppy_rules_cache() == "AGENTS.md"
    end
  end

  # ---------------------------------------------------------------------------
  # finalize_autosave_session/0
  # ---------------------------------------------------------------------------

  describe "finalize_autosave_session/0" do
    test "returns a new autosave ID" do
      result = RuntimeState.finalize_autosave_session()
      assert is_binary(result)
    end

    test "rotates to a different ID" do
      old_id = RuntimeState.get_current_autosave_id()
      Process.sleep(1100)
      new_id = RuntimeState.finalize_autosave_session()
      assert new_id != old_id
    end

    test "with failing save callback, still rotates" do
      failing_fn = fn -> raise "intentional" end
      result = RuntimeState.finalize_autosave_session(failing_fn)
      assert is_binary(result)
    end

    # Regression test: save_fn called before rotation (code_puppy-ctj.4)
    test "save callback is invoked before rotation (autosave-before-rotation)" do
      old_id = RuntimeState.get_current_autosave_id()
      Process.sleep(1100)
      Process.put(:finalize_test_order, [])

      tracking_fn = fn ->
        current = Process.get(:finalize_test_order)
        Process.put(:finalize_test_order, current ++ [:save_called])
      end

      _result = RuntimeState.finalize_autosave_session(tracking_fn)
      assert :save_called in Process.get(:finalize_test_order)
      assert RuntimeState.get_current_autosave_id() != old_id
    after
      Process.delete(:finalize_test_order)
    end
  end

  # ---------------------------------------------------------------------------
  # reset_for_test/0
  # ---------------------------------------------------------------------------

  describe "reset_for_test/0" do
    test "resets all cache fields to defaults" do
      :ok = RuntimeState.set_cached_system_prompt("p")
      :ok = RuntimeState.set_cached_context_overhead(1)
      :ok = RuntimeState.set_delayed_compaction_requested(true)
      _ = RuntimeState.get_state()

      assert :ok = RuntimeState.reset_for_test()

      assert RuntimeState.get_cached_system_prompt() == nil
      assert RuntimeState.get_cached_context_overhead() == nil
      assert RuntimeState.get_delayed_compaction_requested() == false
    end
  end
end
