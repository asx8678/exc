defmodule CodePuppyControl.Tool.RunnerApprovalTest do
  @moduledoc """
  Tests for Tool.Runner AskUser approval integration.

  Covers:
  - AskUser from PolicyEngine records pending request and returns error
  - One-shot approval allows the operation (session-scoped, fingerprint-aware)
  - Non-interactive context returns error with /approve guidance
  - Error message includes /approve guidance (context-aware)
  - Deduplication of pending requests on repeated AskUser
  - Session scoping: approvals from one session don't leak to another
  - Fingerprint scoping: same path + different content does NOT consume approval
  - Fingerprint scoping: same path + same content DOES consume approval
  - Interactive approval via approval_reader injection (approve/deny/eof)
  - Pending recorded before interactive prompt (survives timeout/kill)
  - Inline approval removes pending (no stale entries)
  - One-shot duplicate: only one matching approval consumed, not all

  Note: The interactive CLI prompt path uses an injectable `approval_reader`
  (via context) so tests can simulate yes/no/eof without IO.gets.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Approvals
  alias CodePuppyControl.Approvals.Request
  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.Tool.{Registry, Runner}

  # ── Test Tool Module ──────────────────────────────────────────────────────

  defmodule TestApprovalFileTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :create_file

    @impl true
    def description, do: "Test file creation for approval"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["file_path", "content"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], created: true}}
    end
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Callbacks.Registry
    )

    Registry.clear()
    PolicyEngine.reset()
    Callbacks.clear(:file_permission)

    # Start or reset Approvals
    case Approvals.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        Approvals.clear()
        :ok
    end

    Registry.register(TestApprovalFileTool)

    on_exit(fn ->
      Registry.clear()
      Approvals.clear()
      PolicyEngine.remove_rules_by_source("test_approval")
    end)

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp ask_user_policy do
    PolicyEngine.add_rule(%PolicyRule{
      tool_name: "create_file",
      decision: :ask_user,
      priority: 10,
      source: "test_approval"
    })
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "AskUser approval flow — non-interactive" do
    test "AskUser from policy records pending request and returns error" do
      ask_user_policy()

      result =
        Runner.invoke(:create_file, %{"file_path" => "needs_approval.ex", "content" => "x"}, %{})

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"
      assert reason =~ "/approve last"

      # Pending request should have been recorded
      pending = Approvals.list_pending()
      assert length(pending) == 1
      assert hd(pending).operation == "create"
      assert hd(pending).file_path == "needs_approval.ex"
    end

    test "error message includes guidance about /approve" do
      ask_user_policy()

      result =
        Runner.invoke(:create_file, %{"file_path" => "guidance.ex", "content" => "x"}, %{})

      assert {:error, reason} = result
      assert reason =~ "/approve last"
      assert reason =~ "user approval"
    end

    test "error guidance says /approve last to approve and retry (non-interactive)" do
      ask_user_policy()

      result =
        Runner.invoke(:create_file, %{"file_path" => "guidance2.ex", "content" => "x"}, %{})

      assert {:error, reason} = result
      assert reason =~ "/approve last to approve and retry"
    end

    test "one-shot approval allows the operation" do
      ask_user_policy()

      # Pre-approve: record pending with the same args the Runner will use,
      # so the args_fingerprint matches.
      pre_args = %{"file_path" => "pre_approved.ex", "content" => "y"}

      req =
        Request.new(
          operation: "create",
          file_path: "pre_approved.ex",
          tool_name: "create_file",
          args: pre_args
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      # Now invoke the tool — the approval should be consumed
      result =
        Runner.invoke(:create_file, pre_args, %{})

      assert {:ok, _} = result

      # Approval should have been consumed (one-shot)
      consume =
        Request.new(
          operation: "create",
          file_path: "pre_approved.ex",
          tool_name: "create_file",
          args: pre_args
        )

      assert :no_match = Approvals.consume_approval(consume)
    end

    test "one-shot approval is consumed after successful operation" do
      ask_user_policy()

      # Pre-approve with the exact args the first invocation will use
      first_args = %{"file_path" => "consume_once.ex", "content" => "a"}

      req =
        Request.new(
          operation: "create",
          file_path: "consume_once.ex",
          tool_name: "create_file",
          args: first_args
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      # First invocation should succeed and consume the approval
      result1 =
        Runner.invoke(:create_file, first_args, %{})

      assert {:ok, _} = result1

      # Second invocation should fail — approval was one-shot
      result2 =
        Runner.invoke(:create_file, %{"file_path" => "consume_once.ex", "content" => "b"}, %{})

      assert {:error, reason} = result2
      assert reason =~ "File operation requires user approval"
    end

    test "non-matching approval does not allow the operation" do
      ask_user_policy()

      # Approve a different file
      req = Request.new(operation: "create", file_path: "other.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      result =
        Runner.invoke(:create_file, %{"file_path" => "unapproved.ex", "content" => "z"}, %{})

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"
    end

    test "non-matching tool_name does not allow the operation" do
      ask_user_policy()

      # Approve for a different tool
      req = Request.new(operation: "create", file_path: "wrong_tool.ex", tool_name: "edit_file")
      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      result =
        Runner.invoke(:create_file, %{"file_path" => "wrong_tool.ex", "content" => "z"}, %{})

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"
    end

    test "non-interactive context does not prompt and records pending" do
      ask_user_policy()

      # Empty context = non-interactive (no interactive_approval? or approval_mode)
      result =
        Runner.invoke(:create_file, %{"file_path" => "no_prompt.ex", "content" => "a"}, %{})

      assert {:error, reason} = result
      assert reason =~ "/approve last"

      # Should have recorded a pending request
      pending = Approvals.list_pending()
      assert length(pending) == 1
    end
  end

  describe "AskUser approval flow — session scoping" do
    test "approval from one session does not leak to another" do
      ask_user_policy()

      # Approve for sess-1
      req =
        Request.new(
          operation: "create",
          file_path: "scoped.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last("sess-1")

      # Invoke from sess-2 — should not match
      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "scoped.ex", "content" => "x"},
          %{session_id: "sess-2"}
        )

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"
    end

    test "approval from same session is consumed" do
      ask_user_policy()

      invoke_args = %{"file_path" => "scoped_ok.ex", "content" => "y"}

      req =
        Request.new(
          operation: "create",
          file_path: "scoped_ok.ex",
          tool_name: "create_file",
          session_id: "sess-1",
          args: invoke_args
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last("sess-1")

      result =
        Runner.invoke(
          :create_file,
          invoke_args,
          %{session_id: "sess-1"}
        )

      assert {:ok, _} = result
    end

    test "pending request includes session_id from context" do
      ask_user_policy()

      _result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "ctx_session.ex", "content" => "x"},
          %{session_id: "sess-42"}
        )

      pending = Approvals.list_pending()
      assert length(pending) >= 1

      # Find the request for our file
      req = Enum.find(pending, &(&1.file_path == "ctx_session.ex"))
      assert req != nil
      assert req.session_id == "sess-42"
    end

    test "pending request includes run_id from context" do
      ask_user_policy()

      _result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "ctx_run.ex", "content" => "x"},
          %{run_id: "run-99"}
        )

      pending = Approvals.list_pending()
      req = Enum.find(pending, &(&1.file_path == "ctx_run.ex"))
      assert req != nil
      assert req.run_id == "run-99"
    end
  end

  describe "AskUser approval flow — fingerprint scoping" do
    test "same path + different content does NOT consume approval" do
      ask_user_policy()

      # Pre-approve with content "alpha"
      req =
        Request.new(
          operation: "create",
          file_path: "fingerprint.ex",
          tool_name: "create_file",
          args: %{"file_path" => "fingerprint.ex", "content" => "alpha"}
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      # Invoke with different content "beta" — fingerprints won't match
      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "fingerprint.ex", "content" => "beta"},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"
    end

    test "same path + same content DOES consume approval" do
      ask_user_policy()

      args = %{"file_path" => "fingerprint_match.ex", "content" => "gamma"}

      req =
        Request.new(
          operation: "create",
          file_path: "fingerprint_match.ex",
          tool_name: "create_file",
          args: args
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      result =
        Runner.invoke(
          :create_file,
          args,
          %{}
        )

      assert {:ok, _} = result
    end

    test "pending request includes args_fingerprint from context args" do
      ask_user_policy()

      _result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "fp_test.ex", "content" => "delta"},
          %{}
        )

      pending = Approvals.list_pending()
      req = Enum.find(pending, &(&1.file_path == "fp_test.ex"))
      assert req != nil
      assert req.args_fingerprint != ""
      assert byte_size(req.args_fingerprint) == 64
    end
  end

  describe "AskUser approval flow — deduplication" do
    test "repeated AskUser for the same file does not create duplicate pending requests" do
      ask_user_policy()

      # First invocation
      _result1 =
        Runner.invoke(:create_file, %{"file_path" => "dedup.ex", "content" => "x"}, %{})

      # Second invocation for the same file (same args → same fingerprint → dedup)
      _result2 =
        Runner.invoke(:create_file, %{"file_path" => "dedup.ex", "content" => "x"}, %{})

      # Should have only one pending request (deduped by the Approvals store)
      pending = Approvals.list_pending()
      assert length(pending) == 1
    end

    test "different content creates separate pending requests" do
      ask_user_policy()

      _result1 =
        Runner.invoke(:create_file, %{"file_path" => "dedup2.ex", "content" => "aaa"}, %{})

      _result2 =
        Runner.invoke(:create_file, %{"file_path" => "dedup2.ex", "content" => "bbb"}, %{})

      # Different fingerprints → not deduped
      pending = Approvals.list_pending()
      assert length(pending) == 2
    end
  end

  describe "AskUser approval flow — allow/deny unaffected" do
    test "allow policy still works normally (no AskUser)" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :allow,
        priority: 10,
        source: "test_approval"
      })

      result =
        Runner.invoke(:create_file, %{"file_path" => "allowed.ex", "content" => "x"}, %{})

      assert {:ok, _} = result

      # No pending requests
      assert Approvals.list_pending() == []
    end

    test "deny policy still works normally (no AskUser)" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :deny,
        priority: 10,
        source: "test_approval"
      })

      result =
        Runner.invoke(:create_file, %{"file_path" => "denied.ex", "content" => "x"}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      refute reason =~ "/approve"

      # No pending requests (deny is not AskUser)
      assert Approvals.list_pending() == []
    end
  end

  describe "AskUser approval flow — interactive (approval_reader injection)" do
    test "interactive approval: user approves inline" do
      ask_user_policy()

      # Inject a reader that returns "y\n"
      reader = fn _prompt -> "y\n" end

      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "inline_yes.ex", "content" => "x"},
          %{interactive_approval?: true, approval_reader: reader}
        )

      assert {:ok, _} = result

      # Pending should have been removed (approved inline)
      pending = Approvals.list_pending()
      assert Enum.find(pending, &(&1.file_path == "inline_yes.ex")) == nil
    end

    test "interactive approval: user declines" do
      ask_user_policy()

      # Inject a reader that returns "n\n"
      reader = fn _prompt -> "n\n" end

      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "inline_no.ex", "content" => "x"},
          %{interactive_approval?: true, approval_reader: reader}
        )

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"

      # Pending should still exist (declined, but can be approved later via /approve last)
      pending = Approvals.list_pending()
      assert Enum.find(pending, &(&1.file_path == "inline_no.ex")) != nil
    end

    test "interactive approval: EOF fails closed and leaves pending" do
      ask_user_policy()

      # Inject a reader that returns :eof
      reader = fn _prompt -> :eof end

      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "inline_eof.ex", "content" => "x"},
          %{interactive_approval?: true, approval_reader: reader}
        )

      assert {:error, reason} = result
      assert reason =~ "File operation requires user approval"

      # Pending should still exist (EOF = fail closed, but /approve last can resolve)
      pending = Approvals.list_pending()
      assert Enum.find(pending, &(&1.file_path == "inline_eof.ex")) != nil
    end

    test "pending is recorded BEFORE interactive prompt (survives timeout/kill)" do
      ask_user_policy()

      # Inject a reader that returns "y\n" — but we verify that the pending
      # was recorded before the reader was even called
      pending_before_reader = :atomics.new(1, signed: false)

      reader = fn _prompt ->
        # At the time the reader is called, the pending request should already exist
        count = length(Approvals.list_pending())
        :atomics.put(pending_before_reader, 1, count)
        "y\n"
      end

      _result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "pre_pending.ex", "content" => "x"},
          %{interactive_approval?: true, approval_reader: reader}
        )

      # The pending request was recorded before the reader was invoked
      assert :atomics.get(pending_before_reader, 1) >= 1
    end

    test "interactive approval: various yes forms accepted" do
      for yes_input <- ["y", "Y", "yes", "YES", "Yes"] do
        ask_user_policy()
        Approvals.clear()

        reader = fn _prompt -> "#{yes_input}\n" end

        result =
          Runner.invoke(
            :create_file,
            %{"file_path" => "yes_form.ex", "content" => "x"},
            %{interactive_approval?: true, approval_reader: reader}
          )

        assert {:ok, _} = result,
               "Expected approval for input #{inspect(yes_input)}"
      end
    end

    test "interactive approval with approval_mode: :cli" do
      ask_user_policy()

      reader = fn _prompt -> "y\n" end

      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "cli_mode.ex", "content" => "x"},
          %{approval_mode: :cli, approval_reader: reader}
        )

      assert {:ok, _} = result
    end

    test "interactive error guidance says /approve last to approve and retry" do
      ask_user_policy()

      reader = fn _prompt -> "n\n" end

      result =
        Runner.invoke(
          :create_file,
          %{"file_path" => "guidance_interactive.ex", "content" => "x"},
          %{interactive_approval?: true, approval_reader: reader}
        )

      assert {:error, reason} = result
      assert reason =~ "/approve last to approve and retry"
    end
  end

  describe "AskUser approval flow — one-shot duplicate removal" do
    test "consume_approval removes only one matching approval" do
      ask_user_policy()

      # Create two approvals with different fingerprints
      req1 =
        Request.new(
          operation: "create",
          file_path: "dup_rm.ex",
          tool_name: "create_file",
          session_id: "s1",
          args: %{"content" => "alpha"}
        )

      req2 =
        Request.new(
          operation: "create",
          file_path: "dup_rm.ex",
          tool_name: "create_file",
          session_id: "s2",
          args: %{"content" => "beta"}
        )

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)
      :ok = Approvals.approve_last("s1")
      :ok = Approvals.approve_last("s2")

      # Consume s1's approval (include matching fingerprint)
      consume_s1 =
        Request.new(
          operation: "create",
          file_path: "dup_rm.ex",
          tool_name: "create_file",
          session_id: "s1",
          args: %{"content" => "alpha"}
        )

      assert :allowed = Approvals.consume_approval(consume_s1)

      # s2's approval should still exist
      consume_s2 =
        Request.new(
          operation: "create",
          file_path: "dup_rm.ex",
          tool_name: "create_file",
          session_id: "s2",
          args: %{"content" => "beta"}
        )

      assert :allowed = Approvals.consume_approval(consume_s2)

      # Both consumed
      assert :no_match = Approvals.consume_approval(consume_s1)
    end
  end
end
