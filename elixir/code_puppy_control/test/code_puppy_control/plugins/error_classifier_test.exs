defmodule CodePuppyControl.Plugins.ErrorClassifierTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.{Callbacks, Plugins}
  alias CodePuppyControl.Plugins.ErrorClassifier
  alias CodePuppyControl.Plugins.ErrorClassifier.ExInfo

  setup do
    Callbacks.clear()
    ErrorClassifier.clear()
    :ok
  end

  describe "name/0" do
    test "returns string identifier" do
      assert ErrorClassifier.name() == "error_classifier"
    end
  end

  describe "register/0" do
    test "registers agent_exception and agent_run_end callbacks" do
      assert :ok = ErrorClassifier.register()
      assert Callbacks.count_callbacks(:agent_exception) >= 1
      assert Callbacks.count_callbacks(:agent_run_end) >= 1
    end
  end

  describe "ExInfo" do
    test "formats message with name and description" do
      info = %ExInfo{
        name: "Test Error",
        retry: false,
        description: "Something went wrong",
        severity: :error
      }

      msg = ExInfo.format_message(info, %RuntimeError{message: "test"})
      assert msg =~ "[Test Error]"
      assert msg =~ "Something went wrong"
    end

    test "includes suggestion when present" do
      info = %ExInfo{
        name: "Test Error",
        retry: false,
        description: "Bad thing",
        suggestion: "Try again differently",
        severity: :error
      }

      msg = ExInfo.format_message(info, %RuntimeError{message: "test"})
      assert msg =~ "Suggestion"
      assert msg =~ "Try again differently"
    end

    test "includes retry hint when retryable" do
      info = %ExInfo{
        name: "Transient Error",
        retry: true,
        description: "Temporary issue",
        severity: :warning
      }

      msg = ExInfo.format_message(info, %RuntimeError{message: "test"})
      assert msg =~ "transient"
      assert msg =~ "retry"
    end

    test "converts to map" do
      info = %ExInfo{
        name: "Test Error",
        retry: false,
        description: "Something went wrong",
        severity: :error,
        retry_after_seconds: 5
      }

      map = ExInfo.to_map(info)
      assert map.name == "Test Error"
      assert map.retry == false
      assert map.severity == :error
    end
  end

  describe "exception registry" do
    test "registers and looks up exception info by module" do
      info = %ExInfo{
        name: "Custom Error",
        retry: false,
        description: "Custom error type",
        severity: :error
      }

      ErrorClassifier.register_exception(RuntimeError, info)
      assert ErrorClassifier.get_ex_info(%RuntimeError{message: "test"}) == info
    end

    test "registers and matches pattern-based exceptions" do
      info = %ExInfo{
        name: "Custom Pattern",
        retry: true,
        description: "Pattern matched error",
        severity: :warning,
        retry_after_seconds: 10
      }

      assert :ok = ErrorClassifier.register_pattern("custom.*pattern", info)
      exc = %RuntimeError{message: "Something custom error pattern occurred"}
      assert ErrorClassifier.get_ex_info(exc) == info
    end

    test "returns nil for unknown exceptions" do
      assert ErrorClassifier.get_ex_info(%RuntimeError{message: "totally unknown"}) == nil
    end

    test "classify returns retry flag" do
      info = %ExInfo{name: "Retryable", retry: true, description: "test", severity: :warning}
      ErrorClassifier.register_exception(RuntimeError, info)
      {retry?, ex_info} = ErrorClassifier.classify(%RuntimeError{message: "test"})
      assert retry? == true
      assert ex_info == info
    end

    test "should_retry? returns boolean" do
      info = %ExInfo{name: "Retryable", retry: true, description: "test", severity: :warning}
      ErrorClassifier.register_exception(RuntimeError, info)
      assert ErrorClassifier.should_retry?(%RuntimeError{message: "test"}) == true
    end

    test "get_retry_delay returns configured delay" do
      info = %ExInfo{
        name: "Delayed Retry",
        retry: true,
        description: "test",
        severity: :warning,
        retry_after_seconds: 30
      }

      ErrorClassifier.register_exception(ArgumentError, info)
      assert ErrorClassifier.get_retry_delay(%ArgumentError{}) == 30
    end

    test "get_retry_delay returns 0 for non-retryable errors" do
      assert ErrorClassifier.get_retry_delay(%KeyError{key: :foo}) == 0
    end
  end

  describe "builtin exceptions" do
    test "registers builtins on startup" do
      ErrorClassifier.startup()
      info = ErrorClassifier.get_ex_info(%RuntimeError{message: "test"})
      assert info != nil
      assert info.name == "Runtime Error"
    end

    test "pattern-based rate limit detection" do
      ErrorClassifier.startup()
      exc = %RuntimeError{message: "429 rate limit exceeded"}
      info = ErrorClassifier.get_ex_info(exc)
      assert info != nil
      assert info.retry == true
    end
  end

  describe "loading via Plugins API" do
    test "can be loaded through the plugin system" do
      Plugins.load_plugin(ErrorClassifier)
      assert Callbacks.count_callbacks(:agent_exception) >= 1
    end
  end
end
