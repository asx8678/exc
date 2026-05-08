defmodule CodePuppyControl.TUI.ProgressTest do
  # Not async: tests mutate global environment (TERM / COLORTERM).
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Progress

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp with_no_tty(fun) when is_function(fun, 0) do
    original_term = System.get_env("TERM")
    original_color = System.get_env("COLORTERM")

    System.delete_env("TERM")
    System.delete_env("COLORTERM")

    on_exit(fn ->
      restore_env("TERM", original_term)
      restore_env("COLORTERM", original_color)
    end)

    fun.()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  # ── Spinner ────────────────────────────────────────────────────────────────

  describe "spinner/1" do
    test "returns {:error, :no_tty} when no TTY is available" do
      with_no_tty(fn ->
        assert {:error, :no_tty} = Progress.spinner("test")
      end)
    end
  end

  # ── Bar segments (production code path) ────────────────────────────────────

  describe "compute_bar_segments/3" do
    test "clamps ratio to 1.0 when current exceeds total" do
      seg = Progress.compute_bar_segments(150, 100, 40)
      assert seg.ratio == 1.0
      assert seg.filled == 40
      assert seg.empty == 0
      assert seg.percentage == 100.0
    end

    test "clamps ratio to 0.0 when current is negative" do
      seg = Progress.compute_bar_segments(-10, 100, 40)
      assert seg.ratio == 0.0
      assert seg.filled == 0
      assert seg.empty == 40
      assert seg.percentage == 0.0
    end

    test "computes correct segments for normal ratio" do
      seg = Progress.compute_bar_segments(25, 100, 40)
      assert seg.ratio == 0.25
      assert seg.filled == 10
      assert seg.empty == 30
      assert seg.percentage == 25.0
    end

    test "handles zero total (defaults to ratio 1.0)" do
      seg = Progress.compute_bar_segments(0, 0, 40)
      assert seg.ratio == 1.0
      assert seg.filled == 40
      assert seg.empty == 0
      assert seg.percentage == 100.0
    end

    test "handles current equal to total" do
      seg = Progress.compute_bar_segments(100, 100, 40)
      assert seg.ratio == 1.0
      assert seg.filled == 40
      assert seg.empty == 0
      assert seg.percentage == 100.0
    end

    test "handles current of zero" do
      seg = Progress.compute_bar_segments(0, 100, 40)
      assert seg.ratio == 0.0
      assert seg.filled == 0
      assert seg.empty == 40
      assert seg.percentage == 0.0
    end

    test "percentage rounds to one decimal place" do
      seg = Progress.compute_bar_segments(1, 3, 40)
      # 1/3 * 100 = 33.333..., rounded to 33.3
      assert seg.percentage == 33.3
    end
  end

  # ── Bar TTY guard ──────────────────────────────────────────────────────────

  describe "bar/3" do
    test "returns {:error, :no_tty} when no TTY is available" do
      with_no_tty(fn ->
        assert {:error, :no_tty} = Progress.bar(50, 100, label: "test")
      end)
    end
  end

  # ── Stop ───────────────────────────────────────────────────────────────────

  describe "stop/2" do
    test "does not crash for unknown refs" do
      # stop/2 should be safe even if the ref was never started.
      ref = make_ref()
      assert :ok == Progress.stop(ref)
      assert :ok == Progress.stop(ref, resolution: :error)
    end
  end
end
