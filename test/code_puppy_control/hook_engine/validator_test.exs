defmodule CodePuppyControl.HookEngine.ValidatorTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.HookEngine.Validator

  describe "validate_hooks_config/1" do
    test "accepts empty config" do
      assert {:ok, %{}} = Validator.validate_hooks_config(%{})
    end

    test "accepts valid config" do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "./check.sh"}]}
        ]
      }

      assert {:ok, _} = Validator.validate_hooks_config(config)
    end

    test "rejects non-map input" do
      assert {:error, ["Configuration must be a map"]} =
               Validator.validate_hooks_config("not a map")
    end

    test "rejects unknown event types" do
      assert {:error, errors} = Validator.validate_hooks_config(%{"UnknownType" => []})
      assert Enum.any?(errors, &String.contains?(&1, "Unknown event type"))
    end

    test "skips underscore-prefixed keys" do
      assert {:ok, _} = Validator.validate_hooks_config(%{"_comment" => "skip me"})
    end

    test "rejects non-list hook groups" do
      assert {:error, errors} = Validator.validate_hooks_config(%{"PreToolUse" => "not a list"})
      assert Enum.any?(errors, &String.contains?(&1, "must be a list of hook groups"))
    end

    test "reports missing matcher" do
      config = %{"PreToolUse" => [%{"hooks" => [%{"type" => "command", "command" => "echo"}]}]}

      assert {:error, errors} = Validator.validate_hooks_config(config)
      assert Enum.any?(errors, &String.contains?(&1, "missing required field 'matcher'"))
    end

    test "reports missing hooks field" do
      config = %{"PreToolUse" => [%{"matcher" => "*"}]}

      assert {:error, errors} = Validator.validate_hooks_config(config)
      assert Enum.any?(errors, &String.contains?(&1, "missing required field 'hooks'"))
    end

    test "reports missing hook type" do
      config = %{"PreToolUse" => [%{"matcher" => "*", "hooks" => [%{"command" => "echo"}]}]}

      assert {:error, errors} = Validator.validate_hooks_config(config)
      assert Enum.any?(errors, &String.contains?(&1, "missing required field 'type'"))
    end

    test "reports invalid hook type" do
      config = %{
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "bad", "command" => "echo"}]}
        ]
      }

      assert {:error, errors} = Validator.validate_hooks_config(config)
      assert Enum.any?(errors, &String.contains?(&1, "invalid type"))
    end

    test "reports missing command for command type" do
      config = %{"PreToolUse" => [%{"matcher" => "*", "hooks" => [%{"type" => "command"}]}]}

      assert {:error, errors} = Validator.validate_hooks_config(config)
      assert Enum.any?(errors, &String.contains?(&1, "missing required field 'command'"))
    end

    test "reports invalid timeout" do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [%{"type" => "command", "command" => "echo", "timeout" => 10}]
          }
        ]
      }

      assert {:error, errors} = Validator.validate_hooks_config(config)
      assert Enum.any?(errors, &String.contains?(&1, "timeout"))
    end
  end

  describe "format_validation_report/1" do
    test "formats success report" do
      assert Validator.format_validation_report({:ok, %{}}) == "✓ Configuration is valid"
    end

    test "formats error report with error messages" do
      report = Validator.format_validation_report({:error, ["Error 1", "Error 2"]})
      assert String.contains?(report, "✗ Configuration has 2 error(s)")
      assert String.contains?(report, "Error 1")
      assert String.contains?(report, "Error 2")
    end
  end

  describe "get_config_suggestions/1" do
    test "suggests valid event types" do
      suggestions = Validator.get_config_suggestions(["Unknown event type 'Foo'"])
      assert length(suggestions) > 0
      assert Enum.any?(suggestions, &String.contains?(&1, "Valid event types"))
    end

    test "suggests command format" do
      suggestions = Validator.get_config_suggestions(["missing required field 'command'"])
      assert Enum.any?(suggestions, &String.contains?(&1, "shell commands"))
    end
  end
end
