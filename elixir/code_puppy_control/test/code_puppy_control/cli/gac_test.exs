defmodule CodePuppyControl.CLI.GacTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.CLI.Gac

  describe "help_text/0" do
    test "contains usage line" do
      text = Gac.help_text()
      assert text =~ "usage: gac"
    end

    test "contains all option flags" do
      text = Gac.help_text()

      for flag <- ["--help", "--message", "--no-push", "--dry-run", "--no-stage"] do
        assert text =~ flag, "Expected help text to contain #{flag}"
      end
    end

    test "contains description" do
      text = Gac.help_text()
      assert text =~ "Git Auto Commit"
    end
  end
end
