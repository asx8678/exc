defmodule CodePuppyControl.TUI.LauncherTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Launcher

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

      if legacy,
        do: System.put_env("CODE_PUPPY_TUI", legacy),
        else: System.delete_env("CODE_PUPPY_TUI")
    end
  end

  # ── enabled?/0 ─────────────────────────────────────────────────────────

  describe "enabled?/0" do
    test "returns false when PUP_TUI is not set" do
      with_clean_tui_env(fn ->
        refute Launcher.enabled?()
      end)
    end

    test "returns true when PUP_TUI=1" do
      with_clean_tui_env(fn ->
        System.put_env("PUP_TUI", "1")
        assert Launcher.enabled?()
      end)
    end

    test "returns true when PUP_TUI=true" do
      with_clean_tui_env(fn ->
        System.put_env("PUP_TUI", "true")
        assert Launcher.enabled?()
      end)
    end

    test "legacy CODE_PUPPY_TUI=1 still works (deprecated)" do
      with_clean_tui_env(fn ->
        System.put_env("CODE_PUPPY_TUI", "1")
        # Should return true via legacy fallback
        assert Launcher.enabled?()
      end)
    end
  end

  # ── launch/1 ────────────────────────────────────────────────────────────

  describe "launch/1" do
    test "returns {:error, :tui_disabled} when env var not set" do
      with_clean_tui_env(fn ->
        assert Launcher.launch() == {:error, :tui_disabled}
      end)
    end

    test "force option bypasses env var check" do
      with_clean_tui_env(fn ->
        result = Launcher.launch(force: true)

        # With force: true, we should get past the env-var gate.
        # May fail later (e.g. Owl.LiveScreen unavailable in test),
        # but should NOT be :tui_disabled.
        case result do
          {:ok, _pid} -> :ok
          {:error, reason} -> refute reason == :tui_disabled
        end
      end)
    end
  end

  # ── print_banner/0 ──────────────────────────────────────────────────────

  describe "print_banner/0" do
    test "does not crash when called" do
      # Should complete without error, even in a non-TTY test env
      assert Launcher.print_banner() == :ok
    end
  end
end
