defmodule CodePuppyControl.CLI.SlashCommands.Commands.StagedTest do
  @moduledoc """
  Tests for the /staged slash command.

  Tests parity with Python code_puppy/command_line/staged_commands.py.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.Commands.Staged
  alias CodePuppyControl.Tools.StagedChanges

  setup do
    # Ensure StagedChanges GenServer is started and reset to clean state
    case StagedChanges.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        StagedChanges.clear()
        StagedChanges.disable()
        :ok
    end

    # Clean up any stale save files from previous test runs
    on_exit(fn ->
      # Remove any saved JSON files for the current session
      sid = StagedChanges.session_id()
      stage_dir = Path.join(System.tmp_dir!(), "code_puppy_staged")
      File.rm(Path.join(stage_dir, "#{sid}.json"))
      File.rm(Path.join(stage_dir, "#{sid}.json.tmp"))
      StagedChanges.clear()
      StagedChanges.disable()
    end)

    :ok
  end

  describe "handle_staged/2" do
    test "bare /staged shows summary (returns {:continue, state})" do
      # Capture output
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, :test_state} = Staged.handle_staged("/staged", :test_state)
        end)

      assert output =~ "Staged Changes"
    end

    test "/staged on enables staging mode" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged on", :state)
        end)

      assert output =~ "Staging mode enabled"
      assert StagedChanges.enabled?() == true
    end

    test "/staged off disables staging mode" do
      StagedChanges.enable()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged off", :state)
        end)

      assert output =~ "Staging mode disabled"
      assert StagedChanges.enabled?() == false
    end

    test "/staged diff shows combined diff" do
      StagedChanges.add_create("/tmp/staged_cmd_test.txt", "hello\n", "cmd test")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged diff", :state)
        end)

      assert output =~ "+hello"
    end

    test "/staged diff with no changes shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged diff", :state)
        end)

      assert output =~ "No staged changes to diff"
    end

    test "/staged preview shows preview by file" do
      StagedChanges.add_create("/tmp/preview_test.txt", "data\n", "preview test")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged preview", :state)
        end)

      assert output =~ "Preview of Staged Changes by File"
    end

    test "/staged preview with no changes shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged preview", :state)
        end)

      assert output =~ "No staged changes to preview"
    end

    test "/staged clear removes changes" do
      StagedChanges.add_create("/tmp/clear_test.txt", "x", "clear test")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged clear", :state)
        end)

      assert output =~ "Cleared 1 staged changes"
      assert StagedChanges.count() == 0
    end

    test "/staged clear with no changes shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged clear", :state)
        end)

      assert output =~ "No staged changes to clear"
    end

    test "/staged apply applies changes" do
      path = Path.join(System.tmp_dir!(), "staged_cmd_apply_#{:rand.uniform(100_000)}.txt")
      StagedChanges.add_create(path, "applied!", "apply test")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged apply", :state)
        end)

      assert output =~ "Applied 1 staged changes"
      assert File.exists?(path)

      File.rm(path)
    end

    test "/staged apply with no changes shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged apply", :state)
        end)

      assert output =~ "No staged changes to apply"
    end

    test "/staged reject rejects changes" do
      StagedChanges.add_create("/tmp/reject_test.txt", "x", "reject test")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged reject", :state)
        end)

      assert output =~ "Rejected 1 staged changes"
      assert StagedChanges.count() == 0
    end

    test "/staged reject with no changes shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged reject", :state)
        end)

      assert output =~ "No staged changes to reject"
    end

    test "/staged save persists changes" do
      StagedChanges.add_create("/tmp/save_cmd_test.txt", "x", "save test")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged save", :state)
        end)

      assert output =~ "Staged changes saved to"
    end

    test "/staged load restores changes" do
      StagedChanges.add_create("/tmp/load_cmd_test.txt", "x", "load test")
      StagedChanges.save_to_disk()
      StagedChanges.clear()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged load", :state)
        end)

      assert output =~ "Staged changes loaded from disk"
    end

    test "/staged load with no saved data shows error" do
      # Ensure no save file exists for the current session
      sid = StagedChanges.session_id()
      stage_dir = Path.join(System.tmp_dir!(), "code_puppy_staged")
      File.rm(Path.join(stage_dir, "#{sid}.json"))
      File.rm(Path.join(stage_dir, "#{sid}.json.tmp"))

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged load", :state)
        end)

      assert output =~ "No saved staged changes found"
    end

    test "/staged status shows summary" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged status", :state)
        end)

      assert output =~ "Staged Changes"
    end

    test "/staged summary shows summary (alias)" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged summary", :state)
        end)

      assert output =~ "Staged Changes"
    end

    test "unknown subcommand shows usage" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Staged.handle_staged("/staged bogus", :state)
        end)

      assert output =~ "Usage"
    end
  end
end
