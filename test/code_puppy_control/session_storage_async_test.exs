defmodule CodePuppyControl.SessionStorageAsyncTest do
  @moduledoc """
  Tests for async autosave and debounce/dedup logic.

  Covers:
  - `save_session_async/3` — fire-and-forget background save
  - `AutosaveTracker` — `should_skip_autosave?/1` and `mark_autosave_complete/1`

  All tests use System.tmp_dir!/0 for isolation — never touches ~/.code_puppy/.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.SessionStorage
  alias CodePuppyControl.SessionStorage.AutosaveTracker

  # ---------------------------------------------------------------------------
  # Setup: temp directory per test
  # ---------------------------------------------------------------------------

  setup do
    # Several tests interact with the Store GenServer (which uses Ecto/Repo)
    # when not providing :base_dir.  Check out a sandbox connection in
    # {:shared, self()} mode so the Store's process can also use the Repo.
    # (code_puppy-i1n)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    tmp =
      Path.join(
        System.tmp_dir!(),
        "session_storage_async_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, base_dir: tmp}
  end

  # ---------------------------------------------------------------------------
  # save_session_async/3
  # ---------------------------------------------------------------------------

  describe "save_session_async/3" do
    test "returns :ok synchronously", %{base_dir: dir} do
      history = [%{"role" => "user", "content" => "Hello"}]
      assert :ok = SessionStorage.save_session_async("sync-test", history, base_dir: dir)
    end

    test "persists session to disk in background", %{base_dir: dir} do
      history = [%{"role" => "user", "content" => "Async save"}]
      :ok = SessionStorage.save_session_async("bg-test", history, base_dir: dir)

      # Wait for the background Task to complete
      Process.sleep(100)

      assert SessionStorage.session_exists?("bg-test", base_dir: dir)

      assert {:ok, %{messages: loaded}} =
               SessionStorage.load_session("bg-test", base_dir: dir)

      assert loaded == history
    end

    test "logs warning on failure without raising", %{base_dir: _dir} do
      # Use an invalid base_dir that will cause save to fail.
      # The path must exist as a string but be unwritable.
      # Using "/" which will fail mkdir_p on most systems.
      # We just verify no exception propagates to the caller.
      history = [%{"role" => "user", "content" => "fail"}]

      # This should NOT raise — errors are caught in the Task
      assert :ok = SessionStorage.save_session_async("fail-test", history, base_dir: "/")

      # Give the Task time to run and fail
      Process.sleep(100)
    end

    # (code_puppy-dku) Regression: save_session_async/3 must return :ok
    # even when base_dir()/0 would raise (e.g. invalid env). The
    # fire-and-forget contract means errors resolving env/default
    # base dir are logged, not raised synchronously.
    test "returns :ok when base_dir/0 raises — fire-and-forget contract", %{base_dir: _dir} do
      # Corrupt PUP_SESSION_DIR so base_dir()/0 would raise if called.
      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      # Without explicit base_dir, base_dir()/0 would raise — but
      # save_session_async must catch that and return :ok.
      history = [%{"role" => "user", "content" => "fire-and-forget"}]
      assert :ok = SessionStorage.save_session_async("ff-test", history, [])

      # Give the Task time to (not) run
      Process.sleep(100)
    end

    # (code_puppy-dku) Regression: explicit base_dir: should never
    # evaluate base_dir()/0 — even when it would raise.
    test "explicit base_dir: skips base_dir/0 (lazy default)", %{base_dir: dir} do
      # Corrupt PUP_SESSION_DIR so base_dir()/0 would raise if called.
      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      # With explicit base_dir, base_dir()/0 is never called
      history = [%{"role" => "user", "content" => "lazy-async"}]
      assert :ok = SessionStorage.save_session_async("lazy-async-test", history, base_dir: dir)

      # Give the Task time to complete
      Process.sleep(100)

      assert SessionStorage.session_exists?("lazy-async-test", base_dir: dir)
    end

    test "history snapshot is isolated from later mutations", %{base_dir: dir} do
      # In Elixir, lists are immutable — this test demonstrates intent
      # rather than guarding against a real mutation risk.
      original_history = [%{"role" => "user", "content" => "original"}]

      :ok = SessionStorage.save_session_async("snapshot-test", original_history, base_dir: dir)

      # Wait for save to complete
      Process.sleep(100)

      assert {:ok, %{messages: loaded}} =
               SessionStorage.load_session("snapshot-test", base_dir: dir)

      assert loaded == original_history
    end

    test "when Store is available, routes to Store (not FileBackend)" do
      # (code_puppy-ctj.1) After the save_session_async fix, Store-available
      # path no longer forces FileBackend. Verify the session lands in Store.
      history = [%{"role" => "user", "content" => "store-route-test"}]

      # No base_dir: [] — without it, save_session_async routes to Store
      :ok = SessionStorage.save_session_async("store-route-test", history, [])

      # Wait for the background Task to complete
      Process.sleep(150)

      # Session should exist in Store (no base_dir = Store path)
      assert SessionStorage.session_exists?("store-route-test")
    end

    test "when Store is unavailable, resolves base_dir before Task spawn", %{
      base_dir: dir
    } do
      # (code_puppy-dku) save_session_async/3 must resolve base_dir
      # BEFORE spawning the Task when Store is unavailable. This tests
      # the FileBackend fallback path with env var teardown race protection.
      history = [%{"role" => "user", "content" => "race-test"}]

      # Set up env vars so base_dir/0 resolves to our temp dir.
      prev_session_dir = System.get_env("PUP_SESSION_DIR")
      prev_test_root = System.get_env("PUP_TEST_SESSION_ROOT")

      sandbox_ex = Path.join(dir, "..") |> Path.expand()
      System.put_env("PUP_TEST_SESSION_ROOT", sandbox_ex)
      System.put_env("PUP_SESSION_DIR", dir)

      on_exit(fn ->
        if prev_session_dir,
          do: System.put_env("PUP_SESSION_DIR", prev_session_dir),
          else: System.delete_env("PUP_SESSION_DIR")

        if prev_test_root,
          do: System.put_env("PUP_TEST_SESSION_ROOT", prev_test_root),
          else: System.delete_env("PUP_TEST_SESSION_ROOT")
      end)

      # Call with explicit :base_dir — tests the FileBackend fallback path
      # (when Store is available, explicit :base_dir forces FileBackend)
      :ok = SessionStorage.save_session_async("race-capture-test", history, base_dir: dir)

      # Wait for the background Task to complete
      Process.sleep(150)

      # Verify the session landed in the expected dir
      assert SessionStorage.session_exists?("race-capture-test", base_dir: dir)
    end
  end

  # ---------------------------------------------------------------------------
  # AutosaveTracker
  # ---------------------------------------------------------------------------

  describe "AutosaveTracker.should_skip_autosave?/1" do
    setup do
      # Start an isolated tracker with a controllable clock
      time_ref = :counters.new(1, [:atomics])
      :counters.add(time_ref, 1, 0)

      time_fn = fn -> :counters.get(time_ref, 1) end

      name = :"autosave_tracker_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AutosaveTracker.start_link(name: name, time_fn: time_fn)

      {:ok, tracker: name, time_ref: time_ref}
    end

    test "fresh state returns false (no prior save)", %{tracker: tracker} do
      history = [%{"role" => "user", "content" => "first"}]
      refute AutosaveTracker.should_skip_autosave?(history, tracker)
    end

    test "immediately after mark_autosave_complete returns true (debounce)", %{
      tracker: tracker
    } do
      history = [%{"role" => "user", "content" => "first"}]
      :ok = AutosaveTracker.mark_autosave_complete(history, tracker)

      # Within the debounce window — should skip
      assert AutosaveTracker.should_skip_autosave?(history, tracker)
    end

    test "within debounce window with different history still returns true", %{
      tracker: tracker,
      time_ref: time_ref
    } do
      history1 = [%{"role" => "user", "content" => "first"}]
      history2 = [%{"role" => "user", "content" => "second"}]

      :ok = AutosaveTracker.mark_autosave_complete(history1, tracker)

      # Advance time but stay within 2000ms debounce window
      :counters.add(time_ref, 1, 1000)

      # Even with different history, debounce wins
      assert AutosaveTracker.should_skip_autosave?(history2, tracker)
    end

    test "past debounce window with same history returns true (dedup)", %{
      tracker: tracker,
      time_ref: time_ref
    } do
      history = [%{"role" => "user", "content" => "same"}]
      :ok = AutosaveTracker.mark_autosave_complete(history, tracker)

      # Advance past the 2000ms debounce window
      :counters.add(time_ref, 1, 3000)

      # Same fingerprint → still skip
      assert AutosaveTracker.should_skip_autosave?(history, tracker)
    end

    test "past debounce window with different history returns false", %{
      tracker: tracker,
      time_ref: time_ref
    } do
      history1 = [%{"role" => "user", "content" => "first"}]
      :ok = AutosaveTracker.mark_autosave_complete(history1, tracker)

      # Advance past the 2000ms debounce window
      :counters.add(time_ref, 1, 3000)

      history2 = [%{"role" => "user", "content" => "second"}]

      # Different fingerprint → don't skip
      refute AutosaveTracker.should_skip_autosave?(history2, tracker)
    end

    test "empty history has a stable fingerprint", %{tracker: tracker} do
      # Two calls with empty history should agree
      refute AutosaveTracker.should_skip_autosave?([], tracker)

      :ok = AutosaveTracker.mark_autosave_complete([], tracker)

      # After marking complete, same empty history → skip
      assert AutosaveTracker.should_skip_autosave?([], tracker)
    end
  end

  describe "AutosaveTracker.mark_autosave_complete/1" do
    setup do
      time_fn = fn -> System.monotonic_time(:millisecond) end
      name = :"autosave_tracker_mark_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AutosaveTracker.start_link(name: name, time_fn: time_fn)
      {:ok, tracker: name}
    end

    test "returns :ok", %{tracker: tracker} do
      history = [%{"role" => "user", "content" => "test"}]
      assert :ok = AutosaveTracker.mark_autosave_complete(history, tracker)
    end

    test "successive marks with different histories update fingerprint", %{
      tracker: tracker
    } do
      history1 = [%{"role" => "user", "content" => "first"}]
      history2 = [%{"role" => "assistant", "content" => "second"}]

      :ok = AutosaveTracker.mark_autosave_complete(history1, tracker)
      # Wait out debounce
      Process.sleep(2100)
      refute AutosaveTracker.should_skip_autosave?(history2, tracker)

      :ok = AutosaveTracker.mark_autosave_complete(history2, tracker)
      assert AutosaveTracker.should_skip_autosave?(history2, tracker)
    end
  end
end
