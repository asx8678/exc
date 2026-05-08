defmodule CodePuppyControl.ApprovalsTest do
  @moduledoc """
  Tests for the Approvals GenServer — one-shot approval store for file operations.

  Covers:
  - record_pending / list_pending (global and session-scoped)
  - approve_last (global and session-scoped)
  - consume_approval (matching, fingerprint, and consumption)
  - remove_pending
  - clear
  - Request.new/1 and Request.matches?/2 (with session_id and fingerprint)
  - Request.compute_args_fingerprint/1 and fingerprint_prefix/1
  - Deduplication of pending requests
  - One-shot duplicate removal (only one approval consumed, not all)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Approvals
  alias CodePuppyControl.Approvals.Request

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

  # ── Request struct tests ────────────────────────────────────────────────

  describe "Request.new/1" do
    test "creates request with defaults" do
      req = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      assert req.operation == "create"
      assert req.file_path == "lib/foo.ex"
      assert req.tool_name == "create_file"
      assert req.id > 0
      assert req.inserted_at > 0
      assert req.session_id == nil
      assert req.run_id == nil
      assert req.args_fingerprint == ""
    end

    test "normalizes file path via Path.expand" do
      req = Request.new(operation: "write", file_path: "./bar.ex", tool_name: "replace_in_file")

      assert req.normalized_path == Path.expand("./bar.ex")
      assert req.normalized_path != "./bar.ex"
    end

    test "handles empty file_path" do
      req = Request.new(operation: "read", file_path: "", tool_name: "read_file")

      assert req.file_path == ""
      assert req.normalized_path == ""
    end

    test "handles default values" do
      req = Request.new([])

      assert req.operation == "access"
      assert req.file_path == ""
      assert req.tool_name == ""
      assert req.session_id == nil
      assert req.args_fingerprint == ""
    end

    test "accepts session_id and run_id" do
      req =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          session_id: "sess-1",
          run_id: "run-42"
        )

      assert req.session_id == "sess-1"
      assert req.run_id == "run-42"
    end

    test "computes args_fingerprint from args keyword" do
      args = %{"file_path" => "lib/foo.ex", "content" => "defmodule Foo do\nend\n"}

      req =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: args
        )

      assert req.args_fingerprint != ""
      assert byte_size(req.args_fingerprint) == 64
    end

    test "args_fingerprint is empty string when no args" do
      req = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      assert req.args_fingerprint == ""
    end

    test "args_fingerprint is deterministic for same args" do
      args = %{"a" => "1", "b" => "2"}

      fp1 = Request.compute_args_fingerprint(args)
      fp2 = Request.compute_args_fingerprint(args)

      assert fp1 == fp2
    end

    test "args_fingerprint is order-independent" do
      # Maps in Elixir don't guarantee order, but sorted JSON should be the same
      args1 = %{"a" => "1", "b" => "2"}
      args2 = %{"b" => "2", "a" => "1"}

      assert Request.compute_args_fingerprint(args1) == Request.compute_args_fingerprint(args2)
    end

    test "args_fingerprint differs for different content" do
      args_a = %{"file_path" => "lib/foo.ex", "content" => "hello"}
      args_b = %{"file_path" => "lib/foo.ex", "content" => "world"}

      refute Request.compute_args_fingerprint(args_a) == Request.compute_args_fingerprint(args_b)
    end
  end

  describe "Request.compute_args_fingerprint/1" do
    test "returns empty string for empty map" do
      assert Request.compute_args_fingerprint(%{}) == ""
    end

    test "returns empty string for non-map" do
      assert Request.compute_args_fingerprint("not a map") == ""
      assert Request.compute_args_fingerprint(nil) == ""
    end

    test "returns 64-char lowercase hex for valid map" do
      fp = Request.compute_args_fingerprint(%{"key" => "val"})

      assert byte_size(fp) == 64
      assert fp == String.downcase(fp)
    end
  end

  describe "Request.fingerprint_prefix/1" do
    test "returns first 8 chars of fingerprint" do
      req =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: %{"content" => "x"}
        )

      prefix = Request.fingerprint_prefix(req)
      assert byte_size(prefix) == 8
      assert String.starts_with?(req.args_fingerprint, prefix)
    end

    test "returns empty string for request with no fingerprint" do
      req = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      assert Request.fingerprint_prefix(req) == ""
    end
  end

  describe "Request.matches?/2" do
    test "matches when all fields are equal" do
      a = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")
      b = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      assert Request.matches?(a, b) == true
    end

    test "does not match when operation differs" do
      a = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")
      b = Request.new(operation: "write", file_path: "lib/foo.ex", tool_name: "create_file")

      refute Request.matches?(a, b)
    end

    test "does not match when tool_name differs" do
      a = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")
      b = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "edit_file")

      refute Request.matches?(a, b)
    end

    test "matches on normalized_path, not raw file_path" do
      a = Request.new(operation: "write", file_path: "./bar.ex", tool_name: "replace_in_file")
      abs_path = Path.expand("./bar.ex")
      b = Request.new(operation: "write", file_path: abs_path, tool_name: "replace_in_file")

      assert a.normalized_path == b.normalized_path
      assert Request.matches?(a, b)
    end

    test "matches when both session_ids are nil" do
      a = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")
      b = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      assert Request.matches?(a, b)
    end

    test "does not match when one has session_id and other is nil" do
      a =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      b = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      refute Request.matches?(a, b)
    end

    test "matches when both have same session_id" do
      a =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      b =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      assert Request.matches?(a, b)
    end

    test "does not match when session_ids differ" do
      a =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      b =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          session_id: "sess-2"
        )

      refute Request.matches?(a, b)
    end

    test "matches when both fingerprints are empty (nil / \"\")" do
      a = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")
      # Explicitly set fingerprint to nil
      b = %{a | args_fingerprint: nil}

      assert Request.matches?(a, b)
    end

    test "does not match when fingerprints differ" do
      a =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: %{"content" => "hello"}
        )

      b =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: %{"content" => "world"}
        )

      refute Request.matches?(a, b)
    end

    test "matches when fingerprints are identical" do
      args = %{"content" => "hello"}

      a =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: args
        )

      b =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: args
        )

      assert Request.matches?(a, b)
    end

    test "does not match when one has fingerprint and other is empty" do
      a =
        Request.new(
          operation: "create",
          file_path: "lib/foo.ex",
          tool_name: "create_file",
          args: %{"content" => "hello"}
        )

      b = Request.new(operation: "create", file_path: "lib/foo.ex", tool_name: "create_file")

      refute Request.matches?(a, b)
    end

    test "same path + different content does NOT match (replace_in_file scenario)" do
      a =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: %{"old_str" => "foo", "new_str" => "bar"}
        )

      b =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: %{"old_str" => "baz", "new_str" => "qux"}
        )

      refute Request.matches?(a, b)
    end

    test "same path + same content DOES match" do
      args = %{"old_str" => "foo", "new_str" => "bar"}

      a =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: args
        )

      b =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: args
        )

      assert Request.matches?(a, b)
    end
  end

  # ── Approvals GenServer tests ───────────────────────────────────────────

  describe "record_pending/1 and list_pending/1" do
    test "records and lists pending requests" do
      req = Request.new(operation: "create", file_path: "lib/new.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)

      pending = Approvals.list_pending()
      assert length(pending) == 1
      assert hd(pending).operation == "create"
      assert hd(pending).file_path == "lib/new.ex"
    end

    test "records multiple pending requests" do
      req1 = Request.new(operation: "create", file_path: "a.ex", tool_name: "create_file")
      req2 = Request.new(operation: "write", file_path: "b.ex", tool_name: "replace_in_file")

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      pending = Approvals.list_pending()
      assert length(pending) == 2
    end

    test "deduplicates identical pending requests" do
      req = Request.new(operation: "create", file_path: "lib/dup.ex", tool_name: "create_file")

      :ok = Approvals.record_pending(req)
      :ok = Approvals.record_pending(req)

      pending = Approvals.list_pending()
      assert length(pending) == 1
    end

    test "list_pending/1 filters by session_id" do
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

      # Global list returns both
      assert length(Approvals.list_pending()) == 2

      # Session-scoped list returns only that session's requests
      assert length(Approvals.list_pending("sess-1")) == 1
      assert length(Approvals.list_pending("sess-2")) == 1
      assert hd(Approvals.list_pending("sess-1")).file_path == "a.ex"
      assert hd(Approvals.list_pending("sess-2")).file_path == "b.ex"
    end

    test "list_pending/1 with nil session_id returns all" do
      req1 =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      req2 = Request.new(operation: "write", file_path: "b.ex", tool_name: "replace_in_file")

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      assert length(Approvals.list_pending(nil)) == 2
    end
  end

  describe "approve_last/1" do
    test "approves the most recent pending request" do
      req1 = Request.new(operation: "create", file_path: "a.ex", tool_name: "create_file")
      req2 = Request.new(operation: "write", file_path: "b.ex", tool_name: "replace_in_file")

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      assert :ok = Approvals.approve_last()

      # The most recent (req2) should be removed from pending
      pending = Approvals.list_pending()
      assert length(pending) == 1
      assert hd(pending).operation == "create"
    end

    test "returns error when no pending requests" do
      assert {:error, :none_pending} = Approvals.approve_last()
    end

    test "approved request can be consumed as one-shot" do
      req = Request.new(operation: "create", file_path: "consume.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)

      assert :ok = Approvals.approve_last()

      # Matching consume should succeed
      consume_req =
        Request.new(operation: "create", file_path: "consume.ex", tool_name: "create_file")

      assert :allowed = Approvals.consume_approval(consume_req)

      # Second consume should fail (one-shot)
      assert :no_match = Approvals.consume_approval(consume_req)
    end

    test "approve_last/1 filters by session_id" do
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

      # Approve only sess-2's requests
      assert :ok = Approvals.approve_last("sess-2")

      # sess-2's pending should be gone
      assert Approvals.list_pending("sess-2") == []

      # sess-1's pending should remain
      assert length(Approvals.list_pending("sess-1")) == 1

      # Global pending should have only sess-1
      assert length(Approvals.list_pending()) == 1
    end

    test "approve_last/1 with session_id returns none_pending when no matching" do
      req =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      :ok = Approvals.record_pending(req)

      assert {:error, :none_pending} = Approvals.approve_last("sess-other")
    end

    test "approve_last/1 with nil approves globally (backward compat)" do
      req =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      :ok = Approvals.record_pending(req)

      assert :ok = Approvals.approve_last(nil)
      assert Approvals.list_pending() == []
    end
  end

  describe "consume_approval/1" do
    test "returns no_match when no approvals exist" do
      req = Request.new(operation: "create", file_path: "none.ex", tool_name: "create_file")
      assert :no_match = Approvals.consume_approval(req)
    end

    test "returns no_match when approval does not match" do
      req = Request.new(operation: "create", file_path: "a.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      other = Request.new(operation: "delete", file_path: "b.ex", tool_name: "delete_file")
      assert :no_match = Approvals.consume_approval(other)
    end

    test "consumes matching approval exactly once" do
      req = Request.new(operation: "write", file_path: "oneshot.ex", tool_name: "replace_in_file")
      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      consume =
        Request.new(operation: "write", file_path: "oneshot.ex", tool_name: "replace_in_file")

      assert :allowed = Approvals.consume_approval(consume)
      assert :no_match = Approvals.consume_approval(consume)
    end

    test "matches on normalized path" do
      req = Request.new(operation: "write", file_path: "./rel.ex", tool_name: "replace_in_file")
      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      abs_path = Path.expand("./rel.ex")
      consume = Request.new(operation: "write", file_path: abs_path, tool_name: "replace_in_file")

      assert :allowed = Approvals.consume_approval(consume)
    end

    test "does not match when session_id differs" do
      req =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-1"
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      consume =
        Request.new(
          operation: "create",
          file_path: "a.ex",
          tool_name: "create_file",
          session_id: "sess-2"
        )

      assert :no_match = Approvals.consume_approval(consume)
    end

    test "does not match when args_fingerprint differs" do
      req =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          args: %{"old_str" => "foo", "new_str" => "bar"}
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      consume =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          args: %{"old_str" => "baz", "new_str" => "qux"}
        )

      assert :no_match = Approvals.consume_approval(consume)
    end

    test "same path + different content does NOT consume approval" do
      req =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: %{"old_str" => "foo", "new_str" => "bar"}
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      # Same path, different replacement content
      consume =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: %{"old_str" => "baz", "new_str" => "qux"}
        )

      assert :no_match = Approvals.consume_approval(consume)
    end

    test "same path + same content DOES consume approval" do
      args = %{"old_str" => "foo", "new_str" => "bar"}

      req =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: args
        )

      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      consume =
        Request.new(
          operation: "write",
          file_path: "lib/foo.ex",
          tool_name: "replace_in_file",
          args: args
        )

      assert :allowed = Approvals.consume_approval(consume)
    end

    test "only consumes one matching approval, not all" do
      # Record two identical pending requests — but they'll be deduped
      # So test with two approve_last calls from two separate pending entries
      req1 =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          session_id: "s1"
        )

      req2 =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          session_id: "s2"
        )

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)
      :ok = Approvals.approve_last("s1")
      :ok = Approvals.approve_last("s2")

      # Now consume with a request that matches both (nil session_id match won't work,
      # so use the exact session IDs)
      consume1 =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          session_id: "s1"
        )

      consume2 =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          session_id: "s2"
        )

      # First consume succeeds
      assert :allowed = Approvals.consume_approval(consume1)

      # Second consume also succeeds (different session scope)
      assert :allowed = Approvals.consume_approval(consume2)

      # Third consume fails
      assert :no_match = Approvals.consume_approval(consume1)
    end

    test "consume removes only one matching approval from multiple same-session" do
      # Create two approvals with different fingerprints (different content)
      # so they are distinct but will both match on session/path/tool
      # when consumed without fingerprint
      req1 =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          session_id: "s1",
          args: %{"content" => "alpha"}
        )

      req2 =
        Request.new(
          operation: "write",
          file_path: "a.ex",
          tool_name: "replace_in_file",
          session_id: "s1",
          args: %{"content" => "beta"}
        )

      :ok = Approvals.record_pending(req1)
      :ok = Approvals.record_pending(req2)

      # Approve both manually by adding them to one_shot_approvals
      # (they won't dedupe because fingerprints differ)
      :ok = Approvals.approve_last("s1")
      :ok = Approvals.approve_last("s1")

      # Consume with req1's fingerprint — should only consume one
      assert :allowed = Approvals.consume_approval(req1)

      # req1 is gone, but req2's approval still exists
      assert :allowed = Approvals.consume_approval(req2)

      # Both consumed
      assert :no_match = Approvals.consume_approval(req1)
    end
  end

  describe "remove_pending/1" do
    test "removes a pending request by id" do
      req = Request.new(operation: "create", file_path: "rm.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)

      assert length(Approvals.list_pending()) == 1

      :ok = Approvals.remove_pending(req.id)

      assert Approvals.list_pending() == []
    end

    test "is idempotent for non-existent id" do
      :ok = Approvals.remove_pending(999_999)
    end
  end

  describe "clear/0" do
    test "clears all pending requests and approvals" do
      req = Request.new(operation: "create", file_path: "clear.ex", tool_name: "create_file")
      :ok = Approvals.record_pending(req)
      :ok = Approvals.approve_last()

      :ok = Approvals.clear()

      assert Approvals.list_pending() == []
      assert :no_match = Approvals.consume_approval(req)
    end
  end
end
