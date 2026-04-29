defmodule CodePuppyControl.TUI.SupervisorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Supervisor

  # Helper: save and clear both PUP_TUI and CODE_PUPPY_TUI, restore after
  defp with_clean_tui_env(fun) do
    pup = System.get_env("PUP_TUI")
    legacy = System.get_env("CODE_PUPPY_TUI")
    System.delete_env("PUP_TUI")
    System.delete_env("CODE_PUPPY_TUI")

    try do
      fun.()
    after
      if pup, do: System.put_env("PUP_TUI", pup), else: System.delete_env("PUP_TUI")
      if legacy, do: System.put_env("CODE_PUPPY_TUI", legacy), else: System.delete_env("CODE_PUPPY_TUI")
    end
  end

  # ── Gating ──────────────────────────────────────────────────────────────

  describe "tui gating" do
    test "returns {:error, :tui_disabled} when PUP_TUI is not set" do
      with_clean_tui_env(fn ->
        result = Supervisor.start_link(name: :tui_gate_test_1)
        assert result == {:error, :tui_disabled}
      end)
    end

    test "starts when PUP_TUI=1" do
      with_clean_tui_env(fn ->
        System.put_env("PUP_TUI", "1")

        name = :"tui_gate_test_#{System.unique_integer([:positive])}"
        result = Supervisor.start_link(name: name)

        case result do
          {:ok, pid} ->
            assert Process.alive?(pid)
            Supervisor.stop(name: name)

          {:error, _reason} ->
            # May fail if Owl.LiveScreen is not available in test env,
            # but should not return :tui_disabled
            refute result == {:error, :tui_disabled}
        end
      end)
    end

    test "starts when PUP_TUI=true" do
      with_clean_tui_env(fn ->
        System.put_env("PUP_TUI", "true")

        name = :"tui_gate_test_#{System.unique_integer([:positive])}"
        result = Supervisor.start_link(name: name)

        case result do
          {:ok, pid} ->
            assert Process.alive?(pid)
            Supervisor.stop(name: name)

          {:error, reason} ->
            refute reason == :tui_disabled
        end
      end)
    end

    test "legacy CODE_PUPPY_TUI=1 still works (deprecated)" do
      with_clean_tui_env(fn ->
        System.put_env("CODE_PUPPY_TUI", "1")

        name = :"tui_gate_legacy_#{System.unique_integer([:positive])}"
        result = Supervisor.start_link(name: name)

        case result do
          {:ok, pid} ->
            assert Process.alive?(pid)
            Supervisor.stop(name: name)

          {:error, reason} ->
            refute reason == :tui_disabled
        end
      end)
    end
  end

  # ── stop/1 ──────────────────────────────────────────────────────────────

  describe "stop/1" do
    test "returns :ok when supervisor is not running" do
      assert Supervisor.stop(name: :nonexistent_supervisor_12345) == :ok
    end
  end

  # ── running?/1 ─────────────────────────────────────────────────────────

  describe "running?/1" do
    test "returns false when supervisor is not running" do
      refute Supervisor.running?(name: :nonexistent_supervisor_99999)
    end
  end
end
