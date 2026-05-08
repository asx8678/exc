defmodule CodePuppyControl.REPL.HistoryTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.REPL.History

  # Start a fresh History GenServer for each test.
  # async: false because we share the registered name and the disk file.
  setup do
    # Stop any existing History process
    case Process.whereis(History) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown, 5000)
    end

    # Wipe the history file so tests start clean
    path = History.history_path()
    File.rm(path)

    {:ok, _pid} = History.start_link()

    on_exit(fn ->
      try do
        case Process.whereis(History) do
          nil -> :ok
          pid -> GenServer.stop(pid, :shutdown, 5000)
        end
      catch
        :exit, _ -> :ok
      end

      # Clean up history file after test
      File.rm(path)
    end)

    :ok
  end

  describe "add/1 and all/0" do
    test "adds and retrieves entries" do
      History.add("first")
      History.add("second")
      # Most recent first
      assert History.all() == ["second", "first"]
    end

    test "ignores blank entries" do
      History.add("")
      assert History.all() == []
    end

    test "ignores duplicate of most recent" do
      History.add("hello")
      History.add("hello")
      assert History.all() == ["hello"]
    end

    test "allows same entry after different entry" do
      History.add("hello")
      History.add("world")
      History.add("hello")
      assert History.all() == ["hello", "world", "hello"]
    end

    test "caps at 1000 entries" do
      for i <- 1..1005 do
        History.add("entry-#{i}")
      end

      entries = History.all()
      assert length(entries) == 1000
      # Most recent first
      assert hd(entries) == "entry-1005"
    end
  end

  describe "previous/0 and next/0" do
    test "navigation through history" do
      History.add("alpha")
      History.add("beta")
      History.add("gamma")

      # Start at cursor 0 (no navigation yet)
      assert History.previous() == "gamma"
      assert History.previous() == "beta"
      assert History.previous() == "alpha"
      # Past the end — nil
      assert History.previous() == nil

      # Navigate back toward recent
      assert History.next() == "beta"
      assert History.next() == "gamma"
      # Back to start
      assert History.next() == nil
    end
  end

  describe "search/1" do
    test "finds entries by prefix" do
      History.add("git status")
      History.add("git log")
      History.add("git diff")
      History.add("ls -la")

      assert History.search("git") == ["git diff", "git log", "git status"]
      assert History.search("ls") == ["ls -la"]
      assert History.search("svn") == []
    end
  end

  describe "save/0 and load/0" do
    test "persists and reloads history" do
      History.add("persistent entry")

      # Save to disk
      assert History.save_sync() == :ok

      # Stop the GenServer (trap exits to avoid test crash)
      Process.flag(:trap_exit, true)

      case Process.whereis(History) do
        nil -> :ok
        pid -> GenServer.stop(pid, :shutdown, 5000)
      end

      Process.flag(:trap_exit, false)

      # Start fresh and load
      {:ok, _pid} = History.start_link()
      History.load()

      assert "persistent entry" in History.all()
    end
  end

  describe "reset_cursor/0" do
    test "resets navigation position" do
      History.add("alpha")
      History.add("beta")

      # Navigate away
      _ = History.previous()
      _ = History.previous()
      History.reset_cursor()

      # After reset, previous starts from most recent again
      assert History.previous() == "beta"
    end
  end
end
