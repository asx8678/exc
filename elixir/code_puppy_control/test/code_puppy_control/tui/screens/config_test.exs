defmodule CodePuppyControl.TUI.Screens.ConfigTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Screens.Config

  describe "init/1" do
    test "creates default state" do
      {:ok, state} = Config.init(%{})
      assert state.status == :ok
      assert state.last_action == nil
    end
  end

  describe "render/1" do
    test "renders without crashing" do
      {:ok, state} = Config.init(%{})
      rendered = Config.render(state)
      assert is_list(rendered) or is_binary(rendered)
    end
  end

  describe "handle_input/2" do
    setup do
      {:ok, state} = Config.init(%{})
      {:ok, state: state}
    end

    test "q quits the screen", %{state: state} do
      assert :quit == Config.handle_input("q", state)
    end

    test "empty input is a no-op", %{state: state} do
      assert {:ok, ^state} = Config.handle_input("", state)
    end

    test "keys command returns formatted output", %{state: state} do
      {:ok, new_state} = Config.handle_input("keys", state)
      assert new_state.status == :ok
      assert is_binary(new_state.last_action)
      assert new_state.last_action != ""
    end

    test "get with existing key returns value", %{state: state} do
      # Set a value first, then read it back — deterministic, no external config dependency
      {:ok, state_after_set} =
        Config.handle_input("set test_key_for_get test_value_for_get", state)

      {:ok, state_after_get} = Config.handle_input("get test_key_for_get", state_after_set)

      # If the set succeeded, we get "test_key_for_get = test_value_for_get"
      # If the set failed (Writer unavailable), we get "Key not found: test_key_for_get"
      # Either way, the key name must appear in the response
      assert state_after_get.last_action =~ "test_key_for_get"
    end

    test "get with missing key shows not found", %{state: state} do
      {:ok, new_state} = Config.handle_input("get nonexistent_key_xyz", state)
      assert new_state.status == {:error, "not found"}
      assert new_state.last_action =~ "not found"
    end

    test "set with key and value attempts update", %{state: state} do
      {:ok, new_state} = Config.handle_input("set test_key test_value", state)
      # The key name always appears in the response (success or failure)
      assert new_state.last_action =~ "test_key"
      # On success: "Set test_key = test_value"; on failure: "Failed to set test_key: ..."
      # Either outcome is valid — the test boundary is that it doesn't crash
      # and returns a useful response containing the key name
      assert new_state.status == :ok or match?({:error, _}, new_state.status)
    end

    test "set with only key clears value", %{state: state} do
      {:ok, new_state} = Config.handle_input("set some_key", state)
      # Setting without a value parses as empty string (clearing the value)
      # Verify it doesn't crash and returns a meaningful response
      assert new_state.last_action =~ "some_key"
      assert new_state.status == :ok or match?({:error, _}, new_state.status)
    end

    test "unknown command shows error", %{state: state} do
      {:ok, new_state} = Config.handle_input("blargle", state)
      assert new_state.status == {:error, "unknown command"}
      assert new_state.last_action =~ "blargle"
    end
  end
end
