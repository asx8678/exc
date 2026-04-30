defmodule CodePuppyControl.CLITest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.CLI
  alias CodePuppyControl.CLI.Parser

  describe "resolve_run_mode/1" do
    test "continue wins for real parsed -i -c opts" do
      assert {:ok, opts} = Parser.parse(["-i", "-c"])
      assert opts[:interactive] == true
      assert opts[:continue] == true
      assert opts[:prompt] == nil
      assert CLI.resolve_run_mode(opts) == :continue_session
    end
  end

  describe "help_text/0" do
    test "contains Usage line" do
      text = CLI.help_text()
      assert text =~ "Usage: pup [OPTIONS] [PROMPT]"
    end

    test "contains all option flags" do
      text = CLI.help_text()

      for flag <- [
            "--help",
            "--version",
            "--model MODEL",
            "--agent AGENT",
            "--continue",
            "--prompt PROMPT",
            "--interactive",
            "--bridge-mode"
          ] do
        assert text =~ flag, "Expected help text to contain #{flag}"
      end
    end

    test "contains examples" do
      text = CLI.help_text()
      assert text =~ "Examples:"
      assert text =~ "pup \"explain this code\""
      assert text =~ "Resume latest session"
    end

    test "does not describe --continue as a parsed-only stub" do
      text = CLI.help_text()
      refute text =~ "currently routes"
      refute text =~ "no session restore yet"
    end

    test "contains version from mix project" do
      text = CLI.help_text()
      version = Mix.Project.config()[:version]
      assert text =~ "code-puppy #{version}"
    end
  end
end
