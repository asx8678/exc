defmodule CodePuppyControl.TUI.AppTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.App

  # ── Mock Screens ─────────────────────────────────────────────────────────

  defmodule MockScreen do
    @behaviour CodePuppyControl.TUI.Screen

    @impl true
    def init(opts), do: {:ok, Map.merge(%{label: "mock", count: 0}, opts)}

    @impl true
    def render(state), do: Owl.Data.tag("[#{state.label}:#{state.count}]", :cyan)

    @impl true
    def handle_input("switch", _state), do: {:switch, __MODULE__, %{label: "switched"}}
    def handle_input("quit", _state), do: :quit
    def handle_input(_input, state), do: {:ok, %{state | count: state.count + 1}}

    @impl true
    def cleanup(state) do
      if pid = Map.get(state, :cleanup_pid) do
        send(pid, {:cleaned, state.label})
      end

      :ok
    end
  end

  defmodule OtherScreen do
    @behaviour CodePuppyControl.TUI.Screen

    @impl true
    def init(opts), do: {:ok, Map.merge(%{label: "other"}, opts)}

    @impl true
    def render(state), do: Owl.Data.tag("[#{state.label}]", :magenta)

    @impl true
    def handle_input("quit", _state), do: :quit
    def handle_input(_input, state), do: {:ok, state}
  end

  # Does NOT implement @behaviour — returns non-conforming values
  # to test defensive handling of bad callback returns.
  defmodule BadInitScreen do
    def init(_opts), do: :bork
    def render(_state), do: Owl.Data.tag("[bad]", :red)
    def handle_input(_input, state), do: {:ok, state}
  end

  defmodule FailingInitScreen do
    def init(_opts), do: {:error, :nope}
    def render(_state), do: Owl.Data.tag("[failing]", :red)
    def handle_input(_input, state), do: {:ok, state}
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # Start App with a unique name per test to avoid registration conflicts
    name = :"app_test_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _pid} =
      App.start_link(screen: MockScreen, screen_opts: %{cleanup_pid: self()}, name: name)

    on_exit(fn ->
      case Process.whereis(name) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid, :shutdown, 5000)
          catch
            :exit, _ -> :ok
          end
      end
    end)

    {:ok, app_name: name}
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "initialization" do
    test "starts with the given screen as current", %{app_name: name} do
      assert App.current_screen(name) == MockScreen
    end

    test "stack has one entry", %{app_name: name} do
      stack = App.stack(name)
      assert length(stack) == 1
      {mod, _opts, _state} = hd(stack)
      assert mod == MockScreen
    end
  end

  describe "switch_screen/2" do
    test "replaces current screen", %{app_name: name} do
      :ok = App.switch_screen(OtherScreen, %{}, name)
      assert App.current_screen(name) == OtherScreen
    end

    test "stack still has one entry after switch", %{app_name: name} do
      :ok = App.switch_screen(OtherScreen, %{}, name)
      stack = App.stack(name)
      assert length(stack) == 1
    end

    test "calls cleanup on the replaced screen", %{app_name: name} do
      :ok = App.switch_screen(OtherScreen, %{}, name)
      # MockScreen.cleanup sends a message — we gave cleanup_pid: self()
      assert_received {:cleaned, "mock"}
    end
  end

  describe "push_screen/2 and pop_screen/0" do
    test "push adds a screen on top of the stack", %{app_name: name} do
      :ok = App.push_screen(OtherScreen, %{}, name)
      assert App.current_screen(name) == OtherScreen
      assert length(App.stack(name)) == 2
    end

    test "pop restores the previous screen", %{app_name: name} do
      :ok = App.push_screen(OtherScreen, %{}, name)
      assert App.current_screen(name) == OtherScreen

      :ok = App.pop_screen(name)
      assert App.current_screen(name) == MockScreen
      assert length(App.stack(name)) == 1
    end

    test "pop on single-screen stack is a no-op", %{app_name: name} do
      :ok = App.pop_screen(name)
      assert App.current_screen(name) == MockScreen
      assert length(App.stack(name)) == 1
    end

    test "push multiple screens and pop in order", %{app_name: name} do
      :ok = App.push_screen(OtherScreen, %{}, name)
      :ok = App.push_screen(MockScreen, %{label: "layer3"}, name)

      assert length(App.stack(name)) == 3
      assert App.current_screen(name) == MockScreen

      :ok = App.pop_screen(name)
      assert App.current_screen(name) == OtherScreen

      :ok = App.pop_screen(name)
      assert App.current_screen(name) == MockScreen
    end

    test "pop calls cleanup on the popped screen", %{app_name: name} do
      # Push a MockScreen with cleanup_pid pointing to us
      :ok = App.push_screen(MockScreen, %{cleanup_pid: self(), label: "overlay"}, name)
      :ok = App.pop_screen(name)
      assert_received {:cleaned, "overlay"}
    end
  end

  describe "send_input/1" do
    test "updates screen state on {:ok, new_state}", %{app_name: name} do
      # Send regular input — MockScreen increments count
      App.send_input("hello", name)
      # Give the cast time to process
      Process.sleep(50)

      stack = App.stack(name)
      {_mod, _opts, state} = hd(stack)
      assert state.count == 1
    end

    test "switches screen on {:switch, mod, opts}", %{app_name: name} do
      App.send_input("switch", name)
      Process.sleep(50)
      assert App.current_screen(name) == MockScreen
    end

    test "quits on :quit", %{app_name: name} do
      App.send_input("quit", name)
      Process.sleep(50)
      # The GenServer should have stopped
      refute Process.whereis(name)
    end
  end

  # ── Defensive Handling ──────────────────────────────────────────────────

  # ── Defensive Handling ──────────────────────────────────────────────────

  # These tests manage their own App lifecycle (no shared setup)
  # because they test error-recovery paths where the App must survive
  # bad callback returns.

  describe "defensive error handling" do
    setup do
      name = :"app_defensive_#{System.unique_integer([:positive, :monotonic])}"

      {:ok, _pid} =
        App.start_link(
          screen: MockScreen,
          screen_opts: %{cleanup_pid: self()},
          name: name
        )

      on_exit(fn ->
        if pid = Process.whereis(name) do
          try do
            GenServer.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, app_name: name}
    end

    test "switch_screen returns error and preserves old screen on bad init return", %{
      app_name: name
    } do
      result = App.switch_screen(BadInitScreen, %{}, name)

      assert {:error, {:bad_init_return, :bork}} = result
      # Old screen should still be active — not cleaned up
      assert App.current_screen(name) == MockScreen
      refute_received {:cleaned, _}
    end

    test "switch_screen preserves old screen on explicit {:error, _} init return", %{
      app_name: name
    } do
      result = App.switch_screen(FailingInitScreen, %{}, name)

      assert {:error, :nope} = result
      # Old screen should still be active — cleanup was NOT called
      assert App.current_screen(name) == MockScreen
      refute_received {:cleaned, _}
    end
  end
end
