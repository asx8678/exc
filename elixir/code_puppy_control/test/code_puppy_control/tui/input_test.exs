defmodule CodePuppyControl.TUI.InputTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Input

  # ── Helper ──────────────────────────────────────────────────────────────

  defp start_input(opts \\ []) do
    name =
      Keyword.get_lazy(opts, :name, fn ->
        :"input_test_#{System.unique_integer([:positive])}"
      end)

    {:ok, pid} =
      Input.start_link(
        Keyword.merge(
          [
            app: CodePuppyControl.TUI.App,
            start_reader: false
          ],
          opts
        ) ++ [name: name]
      )

    {pid, name}
  end

  # ── Lifecycle ───────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts with default options" do
      {pid, _name} = start_input()
      assert Process.alive?(pid)
      Input.stop(pid)
    end

    test "starts with custom prompt" do
      {pid, _name} = start_input(prompt: "puppy> ")
      assert Process.alive?(pid)
      Input.stop(pid)
    end
  end

  # ── history management ──────────────────────────────────────────────────

  describe "history/1" do
    test "starts with empty history" do
      {pid, name} = start_input()
      assert Input.history(name) == []
      Input.stop(pid)
    end
  end

  describe "clear_history/1" do
    test "clears history without crashing" do
      {pid, name} = start_input()
      :ok = Input.clear_history(name)
      assert Input.history(name) == []
      Input.stop(pid)
    end
  end

  # ── set_prompt/1 ────────────────────────────────────────────────────────

  describe "set_prompt/2" do
    test "updates prompt without crashing" do
      {pid, name} = start_input()
      :ok = Input.set_prompt(name, "(config)> ")
      Input.stop(pid)
    end
  end

  # ── stop/1 ──────────────────────────────────────────────────────────────

  describe "stop/1" do
    test "stops gracefully" do
      {pid, name} = start_input()
      assert Process.alive?(pid)
      :ok = Input.stop(name)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end
end
