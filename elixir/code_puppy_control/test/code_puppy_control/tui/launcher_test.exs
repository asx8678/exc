defmodule CodePuppyControl.TUI.LauncherTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Launcher

  # ── enabled?/0 ─────────────────────────────────────────────────────────

  describe "enabled?/0" do
    test "returns false when CODE_PUPPY_TUI is not set" do
      original = System.get_env("CODE_PUPPY_TUI")
      System.delete_env("CODE_PUPPY_TUI")

      try do
        refute Launcher.enabled?()
      after
        if original, do: System.put_env("CODE_PUPPY_TUI", original)
      end
    end

    test "returns true when CODE_PUPPY_TUI=1" do
      original = System.get_env("CODE_PUPPY_TUI")
      System.put_env("CODE_PUPPY_TUI", "1")

      try do
        assert Launcher.enabled?()
      after
        if original, do: System.put_env("CODE_PUPPY_TUI", original)
        System.delete_env("CODE_PUPPY_TUI")
      end
    end

    test "returns true when CODE_PUPPY_TUI=true" do
      original = System.get_env("CODE_PUPPY_TUI")
      System.put_env("CODE_PUPPY_TUI", "true")

      try do
        assert Launcher.enabled?()
      after
        if original, do: System.put_env("CODE_PUPPY_TUI", original)
        System.delete_env("CODE_PUPPY_TUI")
      end
    end
  end

  # ── launch/1 ────────────────────────────────────────────────────────────

  describe "launch/1" do
    test "returns {:error, :tui_disabled} when env var not set" do
      original = System.get_env("CODE_PUPPY_TUI")
      System.delete_env("CODE_PUPPY_TUI")

      try do
        assert Launcher.launch() == {:error, :tui_disabled}
      after
        if original, do: System.put_env("CODE_PUPPY_TUI", original)
      end
    end

    test "force option bypasses env var check" do
      original = System.get_env("CODE_PUPPY_TUI")
      System.delete_env("CODE_PUPPY_TUI")

      try do
        result = Launcher.launch(force: true)

        # With force: true, we should get past the env-var gate.
        # May fail later (e.g. Owl.LiveScreen unavailable in test),
        # but should NOT be :tui_disabled.
        case result do
          {:ok, _pid} -> :ok
          {:error, reason} -> refute reason == :tui_disabled
        end
      after
        if original, do: System.put_env("CODE_PUPPY_TUI", original)
      end
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
