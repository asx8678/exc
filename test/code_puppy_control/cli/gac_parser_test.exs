defmodule CodePuppyControl.CLI.GacParserTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.CLI.GacParser

  describe "parse/1 — help flag" do
    test "--help returns {:help, _}" do
      assert {:help, opts} = GacParser.parse(["--help"])
      assert opts[:help] == true
    end

    test "-h returns {:help, _}" do
      assert {:help, opts} = GacParser.parse(["-h"])
      assert opts[:help] == true
    end
  end

  describe "parse/1 — message flag" do
    test "-m with message" do
      assert {:ok, opts} = GacParser.parse(["-m", "feat: add new feature"])
      assert opts[:message] == "feat: add new feature"
    end

    test "--message with message" do
      assert {:ok, opts} = GacParser.parse(["--message", "fix: patch bug"])
      assert opts[:message] == "fix: patch bug"
    end

    test "no message defaults to nil" do
      assert {:ok, opts} = GacParser.parse([])
      assert opts[:message] == nil
    end
  end

  describe "parse/1 — no-push flag" do
    test "--no-push is parsed" do
      assert {:ok, opts} = GacParser.parse(["--no-push"])
      assert opts[:no_push] == true
    end

    test "default is false" do
      assert {:ok, opts} = GacParser.parse([])
      assert opts[:no_push] == false
    end
  end

  describe "parse/1 — dry-run flag" do
    test "--dry-run is parsed" do
      assert {:ok, opts} = GacParser.parse(["--dry-run"])
      assert opts[:dry_run] == true
    end

    test "default is false" do
      assert {:ok, opts} = GacParser.parse([])
      assert opts[:dry_run] == false
    end
  end

  describe "parse/1 — no-stage flag" do
    test "--no-stage is parsed" do
      assert {:ok, opts} = GacParser.parse(["--no-stage"])
      assert opts[:no_stage] == true
    end

    test "default is false" do
      assert {:ok, opts} = GacParser.parse([])
      assert opts[:no_stage] == false
    end
  end

  describe "parse/1 — combined flags" do
    test "-m with --no-push" do
      assert {:ok, opts} = GacParser.parse(["-m", "chore: cleanup", "--no-push"])
      assert opts[:message] == "chore: cleanup"
      assert opts[:no_push] == true
    end

    test "--dry-run with --no-stage" do
      assert {:ok, opts} = GacParser.parse(["--dry-run", "--no-stage"])
      assert opts[:dry_run] == true
      assert opts[:no_stage] == true
    end
  end

  describe "parse/1 — error handling" do
    test "unknown flag returns error" do
      assert {:error, msg} = GacParser.parse(["--bogus"])
      assert msg =~ "bogus"
      refute msg =~ "----", "error message should not have duplicated '--' prefix"
    end

    test "unknown flag error message preserves single '--' prefix" do
      assert {:error, msg} = GacParser.parse(["--nonsense"])
      assert msg =~ "--nonsense"
      refute msg =~ "----nonsense"
    end
  end
end
