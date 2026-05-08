defmodule CodePuppyControl.CLI.SlashCommands.Commands.ApproveTest do
  @moduledoc """
  Tests for the /approve slash command.

  Covers:
  - /approve (bare) shows pending list
  - /approve list shows pending requests (session-scoped)
  - /approve last approves the most recent pending request (session-scoped)
  - /approve clear clears all requests and approvals
  - Unknown subcommand shows usage
  - Fingerprint prefix displayed in list output
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Approvals
  alias CodePuppyControl.Approvals.Request
  alias CodePuppyControl.CLI.SlashCommands.Commands.Approve

  setup do
    # Start or reset the Approvals GenServer for each test
    case Approvals.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Approvals.clear()
        :ok
    end

    on_exit(fn ->
      Approvals.clear()
    end)

    :ok
  end

  describe "handle_approve/2" do
    test "bare /approve shows pending list (returns {:continue, state})" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, :test_state} = Approve.handle_approve("/approve", :test_state)
        end)

      assert output =~ "No pending approval requests"
    end

    test "/approve list shows pending requests" do
      req = Request.new(operation: "create", file_path: "lib/test.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, :state} = Approve.handle_approve("/approve list", :state)
        end)

      assert output =~ "Pending Approval Requests"
      assert output =~ "create"
      assert output =~ "create_file"
      assert output =~ "lib/test.ex"
    end

    test "/approve list with no pending shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve list", :state)
        end)

      assert output =~ "No pending approval requests"
    end

    test "/approve last approves the most recent request" do
      req =
        Request.new(
          operation: "create",
          file_path: "lib/approve_test.ex",
          tool_name: "create_file"
        )

      :ok = Approvals.record_pending(req)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve last", :state)
        end)

      assert output =~ "Approved the most recent pending request"

      # Pending should now be empty
      assert Approvals.list_pending() == []
    end

    test "/approve last with no pending shows message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve last", :state)
        end)

      assert output =~ "No pending approval requests to approve"
    end

    test "/approve clear clears all requests" do
      req = Request.new(operation: "create", file_path: "lib/clear.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve clear", :state)
        end)

      assert output =~ "Cleared all pending requests and approvals"
      assert Approvals.list_pending() == []
    end

    test "unknown subcommand shows usage" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve bogus", :state)
        end)

      assert output =~ "Usage"
      assert output =~ "/approve"
    end

    test "/approve list shows multiple requests" do
      req1 = Request.new(operation: "create", file_path: "a.ex", tool_name: "create_file")
      req2 = Request.new(operation: "write", file_path: "b.ex", tool_name: "replace_in_file")

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve list", :state)
        end)

      assert output =~ "1."
      assert output =~ "2."
      assert output =~ "create"
      assert output =~ "write"
    end
  end

  describe "handle_approve/2 session scoping" do
    test "/approve list with session state filters to that session" do
      req1 =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      req2 =
        Request.new(
          operation: "write",
          file_path: "b.ex",
          tool_name: "replace_in_file",
          session_id: "sess-2"
        )

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      state = %{session_id: "sess-1"}

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve list", state)
        end)

      # Should only show sess-1's request
      assert output =~ "create"
      assert output =~ "a.ex"
      refute output =~ "write"
      refute output =~ "b.ex"
    end

    test "/approve list without session state shows all" do
      req1 =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      req2 =
        Request.new(
          operation: "write",
          file_path: "b.ex",
          tool_name: "replace_in_file",
          session_id: "sess-2"
        )

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      # state is just :state (not a map with session_id)
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve list", :state)
        end)

      assert output =~ "create"
      assert output =~ "write"
    end

    test "/approve last with session state approves only that session" do
      req1 =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      req2 =
        Request.new(
          operation: "write",
          file_path: "b.ex",
          tool_name: "replace_in_file",
          session_id: "sess-2"
        )

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      state = %{session_id: "sess-2"}

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve last", state)
        end)

      assert output =~ "Approved the most recent pending request"

      # sess-1 still pending, sess-2 approved
      assert length(Approvals.list_pending("sess-1")) == 1
      assert Approvals.list_pending("sess-2") == []
    end

    test "/approve last with session state and no matching session shows message" do
      req =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      :ok = Approvals.record_pending(req)

      state = %{session_id: "sess-other"}

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve last", state)
        end)

      assert output =~ "No pending approval requests to approve"
    end
  end

  describe "handle_approve/2 fingerprint display" do
    test "/approve list shows fingerprint prefix when present" do
      req =
        Request.new(
          operation: "create",
          file_path: "lib/fp.ex",
          tool_name: "create_file",
          args: %{"content" => "hello world"}
        )

      :ok = Approvals.record_pending(req)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve list", :state)
        end)

      # The fingerprint prefix (8 chars) should appear in square brackets
      prefix = Request.fingerprint_prefix(req)
      assert output =~ "[#{prefix}]"
    end

    test "/approve list omits fingerprint when absent" do
      req = Request.new(operation: "create", file_path: "lib/nofp.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Approve.handle_approve("/approve list", :state)
        end)

      # No [xxxx] fingerprint prefix should appear
      refute output =~ ~r/\[[0-9a-f]{8}\]/
    end
  end
end
