defmodule CodePuppyControl.Config.IsolationTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.Isolation

  @home Path.expand("~")

  setup do
    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")

      # Clean up any sandbox state
      Process.delete(:isolation_sandbox)
    end)

    :ok
  end

  # ── allowed?/1 ──────────────────────────────────────────────────────────

  describe "allowed?/1" do
    test "returns true for paths under ~/.code_puppy_ex" do
      ex_path = Path.join(@home, ".code_puppy_ex/some_file")
      assert Isolation.allowed?(ex_path)
    end

    test "returns true for paths under PUP_EX_HOME override" do
      tmp_dir = System.tmp_dir!()
      System.put_env("PUP_EX_HOME", tmp_dir)

      try do
        ex_path = Path.join(tmp_dir, "some_file")
        assert Isolation.allowed?(ex_path)
      after
        System.delete_env("PUP_EX_HOME")
      end
    end

    test "returns false for paths under legacy home" do
      legacy_path = Path.join(@home, ".code_puppy/some_file")
      refute Isolation.allowed?(legacy_path)
    end

    test "returns false for the legacy home directory itself" do
      refute Isolation.allowed?(Path.join(@home, ".code_puppy"))
    end

    test "returns true for paths outside both homes" do
      assert Isolation.allowed?("/tmp/foo/bar")
    end
  end

  # ── safe_write!/2 ───────────────────────────────────────────────────────

  describe "safe_write!/2" do
    test "raises IsolationViolation when target is under legacy home" do
      legacy_path = Path.join(@home, ".code_puppy/blocked_write.txt")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_write!(legacy_path, "data")
      end
    end

    test "succeeds when target is outside legacy home" do
      tmp_dir = Path.join(System.tmp_dir!(), "iso_write_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      test_file = Path.join(tmp_dir, "safe_write_test.txt")

      try do
        assert Isolation.safe_write!(test_file, "hello") == :ok
        assert File.read!(test_file) == "hello"
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  # ── safe_mkdir_p!/1 ─────────────────────────────────────────────────────

  describe "safe_mkdir_p!/1" do
    test "raises IsolationViolation when target is under legacy home" do
      legacy_path = Path.join(@home, ".code_puppy/blocked_dir")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_mkdir_p!(legacy_path)
      end
    end

    test "succeeds when target is outside legacy home" do
      tmp_dir = Path.join(System.tmp_dir!(), "iso_mkdir_#{:erlang.unique_integer([:positive])}")
      test_dir = Path.join(tmp_dir, "safe_mkdir_test")

      try do
        assert Isolation.safe_mkdir_p!(test_dir) == :ok
        assert File.dir?(test_dir)
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  # ── safe_rm!/1 ──────────────────────────────────────────────────────────

  describe "safe_rm!/1" do
    test "raises IsolationViolation when target is under legacy home" do
      legacy_path = Path.join(@home, ".code_puppy/blocked_rm.txt")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_rm!(legacy_path)
      end
    end

    test "succeeds when target is outside legacy home" do
      tmp_dir = Path.join(System.tmp_dir!(), "iso_rm_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      test_file = Path.join(tmp_dir, "safe_rm_test.txt")
      File.write!(test_file, "temp")

      try do
        assert Isolation.safe_rm!(test_file) == :ok
        refute File.exists?(test_file)
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  # ── safe_rm_rf!/1 ───────────────────────────────────────────────────────

  describe "safe_rm_rf!/1" do
    test "raises IsolationViolation when target is under legacy home" do
      legacy_path = Path.join(@home, ".code_puppy/blocked_rmrf")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_rm_rf!(legacy_path)
      end
    end

    test "succeeds when target is outside legacy home" do
      tmp_dir = Path.join(System.tmp_dir!(), "iso_rmrf_#{:erlang.unique_integer([:positive])}")
      test_dir = Path.join(tmp_dir, "safe_rmrf_test")
      File.mkdir_p!(test_dir)

      try do
        assert {:ok, _} = Isolation.safe_rm_rf!(test_dir)
        refute File.dir?(test_dir)
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  # ── Symlink attack test ─────────────────────────────────────────────────

  describe "symlink attack prevention" do
    test "safe_write! raises when target is a symlink to legacy home" do
      tmp_dir = System.tmp_dir!()
      link_path = Path.join(tmp_dir, "evil_link_#{:erlang.unique_integer([:positive])}")
      legacy_target = Path.join(@home, ".code_puppy/attacked_file")

      :ok = :file.make_symlink(legacy_target, String.to_charlist(link_path))

      try do
        assert_raise Isolation.IsolationViolation, fn ->
          Isolation.safe_write!(link_path, "evil data")
        end
      after
        File.rm(link_path)
      end
    end

    test "allowed? returns false for symlink pointing into legacy home" do
      tmp_dir = System.tmp_dir!()
      link_path = Path.join(tmp_dir, "evil_allowed_#{:erlang.unique_integer([:positive])}")
      legacy_target = Path.join(@home, ".code_puppy/some_path")

      :ok = :file.make_symlink(legacy_target, String.to_charlist(link_path))

      try do
        refute Isolation.allowed?(link_path)
      after
        File.rm(link_path)
      end
    end
  end

  # ── with_sandbox/2 ──────────────────────────────────────────────────────

  describe "with_sandbox/2" do
    test "lifts the guard for whitelisted paths" do
      unique_dir =
        Path.join(@home, ".code_puppy/_isolation_test_#{:erlang.unique_integer([:positive])}")

      test_file = Path.join(unique_dir, "test.txt")

      File.mkdir_p!(unique_dir)

      try do
        # Without sandbox, the path is not allowed
        refute Isolation.allowed?(test_file)

        Isolation.with_sandbox([test_file], fn ->
          # With sandbox, the path is allowed
          assert Isolation.allowed?(test_file)

          # And safe_write! succeeds
          assert Isolation.safe_write!(test_file, "sandboxed content") == :ok
        end)

        # After sandbox, path is blocked again
        refute Isolation.allowed?(test_file)

        # Verify the file was actually written
        assert File.read!(test_file) == "sandboxed content"
      after
        File.rm_rf(unique_dir)
      end
    end

    test "does not leak sandbox state after exit" do
      legacy_path = Path.join(@home, ".code_puppy/leak_test")

      refute Isolation.allowed?(legacy_path)

      Isolation.with_sandbox([legacy_path], fn ->
        assert Isolation.allowed?(legacy_path)
      end)

      refute Isolation.allowed?(legacy_path)
    end
  end

  # ── Nested sandbox ─────────────────────────────────────────────────────

  describe "nested sandbox" do
    test "inner sandbox is additive with outer" do
      path_a = Path.join(@home, ".code_puppy/nested_a")
      path_b = Path.join(@home, ".code_puppy/nested_b")

      # Neither is allowed without sandbox
      refute Isolation.allowed?(path_a)
      refute Isolation.allowed?(path_b)

      Isolation.with_sandbox([path_a], fn ->
        # Outer: only path_a is allowed
        assert Isolation.allowed?(path_a)
        refute Isolation.allowed?(path_b)

        Isolation.with_sandbox([path_b], fn ->
          # Inner: both are allowed (additive)
          assert Isolation.allowed?(path_a)
          assert Isolation.allowed?(path_b)
        end)

        # Back to outer: only path_a again
        assert Isolation.allowed?(path_a)
        refute Isolation.allowed?(path_b)
      end)

      # Outside: neither is allowed
      refute Isolation.allowed?(path_a)
      refute Isolation.allowed?(path_b)
    end

    test "inner sandbox exit restores outer sandbox, not just deletes" do
      path_a = Path.join(@home, ".code_puppy/restore_a")
      path_b = Path.join(@home, ".code_puppy/restore_b")

      Isolation.with_sandbox([path_a], fn ->
        assert Isolation.allowed?(path_a)

        Isolation.with_sandbox([path_b], fn ->
          assert Isolation.allowed?(path_a)
          assert Isolation.allowed?(path_b)
        end)

        # Critical: path_a should still be allowed after inner exit
        assert Isolation.allowed?(path_a)
        refute Isolation.allowed?(path_b)
      end)
    end
  end

  # ── Parallel test isolation ─────────────────────────────────────────────

  describe "parallel test isolation" do
    test "different processes have independent sandbox state" do
      path_a = Path.join(@home, ".code_puppy/parallel_a")
      path_b = Path.join(@home, ".code_puppy/parallel_b")

      # Helper that checks allowed? from a spawned task
      check_allowed = fn path ->
        Task.async(fn -> Isolation.allowed?(path) end) |> Task.await()
      end

      # Before any sandbox: both blocked
      refute Isolation.allowed?(path_a)
      refute Isolation.allowed?(path_b)

      # Set up sandbox in current process
      Isolation.with_sandbox([path_a], fn ->
        assert Isolation.allowed?(path_a)

        # Spawned task (different process) should NOT see our sandbox
        refute check_allowed.(path_a)

        # Spawn two tasks with different sandboxes
        task1 =
          Task.async(fn ->
            Isolation.with_sandbox([path_a], fn ->
              Isolation.allowed?(path_a)
            end)
          end)

        task2 =
          Task.async(fn ->
            Isolation.with_sandbox([path_b], fn ->
              Isolation.allowed?(path_b)
            end)
          end)

        result1 = Task.await(task1)
        result2 = Task.await(task2)

        assert result1 == true
        assert result2 == true

        # Current process still only has path_a
        assert Isolation.allowed?(path_a)
        refute Isolation.allowed?(path_b)
      end)
    end
  end

  # ── Telemetry emission ──────────────────────────────────────────────────

  describe "telemetry" do
    test "violation emits telemetry event with correct metadata" do
      legacy_path = Path.join(@home, ".code_puppy/telemetry_test")

      # Attach a handler to capture the event
      test_pid = self()
      handler_id = "isolation_test_#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:code_puppy_control, :config, :isolation_violation],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      try do
        assert_raise Isolation.IsolationViolation, fn ->
          Isolation.safe_write!(legacy_path, "telemetry test")
        end

        assert_received {:telemetry_event, event_name, measurements, metadata}

        assert event_name == [:code_puppy_control, :config, :isolation_violation]
        assert measurements.count == 1
        assert metadata.action == :write
        assert metadata.path =~ ".code_puppy"
        assert metadata.process == self()
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  # ── read_only_legacy/1 ──────────────────────────────────────────────────

  describe "read_only_legacy/1" do
    test "raises ArgumentError for paths outside legacy home" do
      assert_raise ArgumentError, fn ->
        Isolation.read_only_legacy("/tmp/not_legacy")
      end
    end

    test "reads file from legacy home when it exists" do
      unique_dir =
        Path.join(
          @home,
          ".code_puppy/_isolation_read_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(unique_dir)
      test_file = Path.join(unique_dir, "read_test.txt")
      File.write!(test_file, "legacy content")

      try do
        assert {:ok, "legacy content"} = Isolation.read_only_legacy(test_file)
      after
        File.rm_rf(unique_dir)
      end
    end

    test "returns error for non-existent file in legacy home" do
      legacy_path =
        Path.join(@home, ".code_puppy/nonexistent_#{:erlang.unique_integer([:positive])}.txt")

      assert {:error, :enoent} = Isolation.read_only_legacy(legacy_path)
    end
  end

  # ── IsolationViolation exception ────────────────────────────────────────

  describe "IsolationViolation" do
    test "contains resolved path and action in exception" do
      legacy_path = Path.join(@home, ".code_puppy/exception_test")

      error =
        assert_raise Isolation.IsolationViolation, fn ->
          Isolation.safe_write!(legacy_path, "data")
        end

      assert error.path =~ ".code_puppy"
      assert error.action == :write
      assert Exception.message(error) =~ "blocked"
      assert Exception.message(error) =~ "write"
    end
  end
end
