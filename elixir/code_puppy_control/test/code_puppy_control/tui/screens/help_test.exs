defmodule CodePuppyControl.TUI.Screens.HelpTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Screens.Help

  describe "init/1" do
    test "creates state with previous_screen from opts" do
      {:ok, state} = Help.init(%{previous_screen: SomeScreen})
      assert state.previous_screen == SomeScreen
    end

    test "creates state with nil previous_screen by default" do
      {:ok, state} = Help.init(%{})
      assert state.previous_screen == nil
    end
  end

  describe "render/1" do
    test "renders without crashing" do
      {:ok, state} = Help.init(%{})
      rendered = Help.render(state)
      assert is_list(rendered) or is_binary(rendered)
    end
  end

  describe "handle_input/2" do
    setup do
      {:ok, state} = Help.init(%{})
      {:ok, state: state}
    end

    test "q quits the screen", %{state: state} do
      assert :quit == Help.handle_input("q", state)
    end

    test "empty string quits the screen", %{state: state} do
      assert :quit == Help.handle_input("", state)
    end

    test "other input is ignored (no-op)", %{state: state} do
      assert {:ok, ^state} = Help.handle_input("random text", state)
    end
  end
end
