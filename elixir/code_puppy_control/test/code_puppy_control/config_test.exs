defmodule CodePuppyControl.ConfigTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Config

  describe "cli_help_or_version_flag?/1" do
    test "returns true for --help" do
      assert Config.cli_help_or_version_flag?(["--help"])
    end

    test "returns true for -h" do
      assert Config.cli_help_or_version_flag?(["-h"])
    end

    test "returns true for --version" do
      assert Config.cli_help_or_version_flag?(["--version"])
    end

    test "returns true for -v" do
      assert Config.cli_help_or_version_flag?(["-v"])
    end

    test "returns true for -V" do
      assert Config.cli_help_or_version_flag?(["-V"])
    end

    test "returns true when flag is among other args" do
      assert Config.cli_help_or_version_flag?(["prompt", "--help"])
    end

    test "returns false for regular prompts" do
      refute Config.cli_help_or_version_flag?(["prompt", "--model", "gpt-4"])
    end

    test "returns false for empty list" do
      refute Config.cli_help_or_version_flag?([])
    end

    test "returns false for non-list input" do
      refute Config.cli_help_or_version_flag?("not a list")
    end

    test "accepts charlists (erlang :init.get_plain_arguments format)" do
      # :init.get_plain_arguments/0 returns charlists
      assert Config.cli_help_or_version_flag?([~c"--help"])
    end

    test "accepts binaries (System.argv format)" do
      # System.argv/0 returns binary strings
      assert Config.cli_help_or_version_flag?(["--version"])
    end
  end

  describe "escript_mode?/0" do
    test "returns false in test/dev environment (priv_dir is valid)" do
      # In the test environment, :code.priv_dir(:code_puppy_control) returns
      # a valid directory, so escript_mode?() should be false.
      refute Config.escript_mode?(),
             "escript_mode?() should return false in test/dev environment"
    end
  end

  describe "burrito_binary?/0" do
    test "returns false when __BURRITO env var is not set" do
      # Clear __BURRITO if set
      System.delete_env("__BURRITO")
      refute Config.burrito_binary?()
    end
  end
end
