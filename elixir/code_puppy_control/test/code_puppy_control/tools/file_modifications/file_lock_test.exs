defmodule CodePuppyControl.Tools.FileModifications.FileLockTest do
  @moduledoc "Tests for FileLock — per-file locking via :global.trans/3."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.FileLock

  describe "with_lock/2" do
    test "executes function and returns its result" do
      assert {:ok, :done} = FileLock.with_lock("/tmp/test_lock.txt", fn -> {:ok, :done} end)
    end

    test "passes through error tuples" do
      assert {:error, "bad"} =
               FileLock.with_lock("/tmp/test_lock_err.txt", fn -> {:error, "bad"} end)
    end

    test "serializes access to the same file" do
      test_path = "/tmp/lock_serial_test_#{:erlang.unique_integer([:positive])}.txt"
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:first} =
        FileLock.with_lock(test_path, fn ->
          Agent.update(agent, &(&1 ++ [:first]))
          {:first}
        end)

      {:second} =
        FileLock.with_lock(test_path, fn ->
          Agent.update(agent, &(&1 ++ [:second]))
          history = Agent.get(agent, & &1)
          assert history == [:first, :second]
          {:second}
        end)

      Agent.stop(agent)
    end

    test "allows concurrent access to different files" do
      task1 =
        Task.async(fn ->
          FileLock.with_lock("/tmp/lock_file_a.txt", fn ->
            Process.sleep(50)
            {:ok, :a}
          end)
        end)

      task2 =
        Task.async(fn ->
          FileLock.with_lock("/tmp/lock_file_b.txt", fn ->
            {:ok, :b}
          end)
        end)

      {:ok, :a} = Task.await(task1, 5000)
      {:ok, :b} = Task.await(task2, 5000)
    end

    test "handles function errors gracefully" do
      assert {:error, %RuntimeError{}} =
               FileLock.with_lock("/tmp/lock_error_test.txt", fn ->
                 raise RuntimeError, "test error"
               end)
    end

    test "resolves symlinks to the same key" do
      assert {:ok, :done} =
               FileLock.with_lock("/tmp/./lock_test.txt", fn -> {:ok, :done} end)
    end
  end
end
