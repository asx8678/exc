defmodule CodePuppyControl.REPL.DispatchErrorFormatTest do
  @moduledoc """
  Tests for REPL.Dispatch.print_agent_error/1 user-facing error formatting.

  Verifies that authentication-related errors (:not_authenticated,
  :missing_account_id) produce actionable user messages instead of raw atoms.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.REPL.Dispatch

  describe "print_agent_error/1" do
    test ":not_authenticated prints actionable auth message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Dispatch.print_agent_error(:not_authenticated)
        end)

      assert output =~ "not authenticated"
      assert output =~ "/chatgpt-auth"
      assert output =~ "/claude-code-auth"
      refute output =~ ":not_authenticated"
    end

    test ":missing_account_id prints actionable account_id message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Dispatch.print_agent_error(:missing_account_id)
        end)

      assert output =~ "account_id"
      assert output =~ "/chatgpt-auth"
      refute output =~ ":missing_account_id"
    end

    test "binary message prints as-is with warning prefix" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Dispatch.print_agent_error("Something went wrong")
        end)

      assert output =~ "⚠"
      assert output =~ "Something went wrong"
    end

    test "other atoms are inspected (generic fallback)" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Dispatch.print_agent_error(:some_other_error)
        end)

      assert output =~ ":some_other_error"
    end
  end
end
