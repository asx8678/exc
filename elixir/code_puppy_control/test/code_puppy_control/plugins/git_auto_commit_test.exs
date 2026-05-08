defmodule CodePuppyControl.Plugins.GitAutoCommitTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.{Callbacks, Plugins}
  alias CodePuppyControl.Plugins.GitAutoCommit

  setup do
    Callbacks.clear()
    :ok
  end

  describe "name/0" do
    test "returns string identifier" do
      assert GitAutoCommit.name() == "git_auto_commit"
    end
  end

  describe "description/0" do
    test "returns a non-empty description" do
      assert is_binary(GitAutoCommit.description())
      assert GitAutoCommit.description() != ""
    end
  end

  describe "register/0" do
    test "registers custom_command and custom_command_help callbacks" do
      assert :ok = GitAutoCommit.register()
      assert Callbacks.count_callbacks(:custom_command) >= 1
      assert Callbacks.count_callbacks(:custom_command_help) >= 1
    end
  end

  describe "command_help/0" do
    test "returns help entries for commit commands" do
      help = GitAutoCommit.command_help()
      assert is_list(help)
      assert length(help) == 4
      commands = Enum.map(help, fn {cmd, _desc} -> cmd end)
      assert "/commit" in commands
      assert "/commit status" in commands
      assert "/commit preview" in commands
    end
  end

  describe "handle_command/2" do
    test "returns nil for unknown command name" do
      assert GitAutoCommit.handle_command("/foo", "foo") == nil
    end
  end

  describe "loading via Plugins API" do
    test "can be loaded through the plugin system" do
      Plugins.load_plugin(GitAutoCommit)
      assert Callbacks.count_callbacks(:custom_command) >= 1
    end
  end

  describe "handle_command with git repo" do
    setup context do
      # Only set up a git repo for tests that opt in
      unless context[:with_git_repo] do
        {:ok, tmp_dir: nil}
      else
        tmp_dir = Path.join(System.tmp_dir!(), "gac_test_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(tmp_dir)

        original_dir = File.cwd!()
        File.cd!(tmp_dir)

        # Initialise a git repo with a commit so HEAD exists
        System.cmd("git", ["init"], stderr_to_stdout: true)
        System.cmd("git", ["config", "user.email", "test@test.com"], stderr_to_stdout: true)
        System.cmd("git", ["config", "user.name", "Test"], stderr_to_stdout: true)
        File.write!(Path.join(tmp_dir, "initial.txt"), "init")
        System.cmd("git", ["add", "initial.txt"], stderr_to_stdout: true)
        System.cmd("git", ["commit", "-m", "initial"], stderr_to_stdout: true)

        on_exit(fn ->
          File.cd!(original_dir)
          File.rm_rf!(tmp_dir)
        end)

        {:ok, tmp_dir: tmp_dir}
      end
    end

    @tag :with_git_repo
    test "/commit status reports staged file count", %{tmp_dir: tmp_dir} do
      # Create and stage a file
      File.write!(Path.join(tmp_dir, "new_file.txt"), "hello")
      System.cmd("git", ["add", "new_file.txt"], stderr_to_stdout: true)

      result = GitAutoCommit.handle_command("/commit status", "commit")
      assert is_binary(result)
      assert result =~ ~r/staged/i
    end

    @tag :with_git_repo
    test "/commit status reports no staged changes", %{tmp_dir: _tmp_dir} do
      result = GitAutoCommit.handle_command("/commit status", "commit")
      assert result =~ ~r/clean|no staged|nothing/i
    end

    @tag :with_git_repo
    test "/commit preview shows diff summary", %{tmp_dir: tmp_dir} do
      # Create and stage a file
      File.write!(Path.join(tmp_dir, "preview_file.txt"), "preview content")
      System.cmd("git", ["add", "preview_file.txt"], stderr_to_stdout: true)

      result = GitAutoCommit.handle_command("/commit preview", "commit")
      assert is_binary(result)
    end

    @tag :with_git_repo
    test "/commit -m executes commit with staged files", %{tmp_dir: tmp_dir} do
      # Create and stage a file
      File.write!(Path.join(tmp_dir, "commit_file.txt"), "commit content")
      System.cmd("git", ["add", "commit_file.txt"], stderr_to_stdout: true)

      result = GitAutoCommit.handle_command("/commit -m test commit message", "commit")
      assert is_binary(result)
      assert result =~ ~r/committed|success/i
    end

    @tag :with_git_repo
    test "/commit without -m prompts for message", %{tmp_dir: tmp_dir} do
      # Create and stage a file
      File.write!(Path.join(tmp_dir, "prompt_file.txt"), "prompt content")
      System.cmd("git", ["add", "prompt_file.txt"], stderr_to_stdout: true)

      result = GitAutoCommit.handle_command("/commit", "commit")
      assert result =~ ~r/-m/i
    end

    test "/commit when not in git repo returns error" do
      original_dir = File.cwd!()
      non_git = Path.join(System.tmp_dir!(), "non_git_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(non_git)
      File.cd!(non_git)

      on_exit(fn ->
        File.cd!(original_dir)
        File.rm_rf!(non_git)
      end)

      result = GitAutoCommit.handle_command("/commit", "commit")
      assert is_binary(result)
    end
  end
end
