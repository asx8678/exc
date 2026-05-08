defmodule CodePuppyControlWeb.Admin.DataTest do
  @moduledoc """
  Unit tests for the admin data adapter — the single read seam between
  the LiveView UI and the runtime.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControlWeb.Admin.Data

  describe "parse_worktree_porcelain/1" do
    test "parses a typical multi-worktree output" do
      output = """
      worktree /tmp/main
      HEAD abc123def456
      branch refs/heads/main

      worktree /tmp/feature
      HEAD 999aaa888bbb
      branch refs/heads/feature/foo

      worktree /tmp/detached
      HEAD 111222333444
      detached
      """

      [main, feature, detached] = Data.parse_worktree_porcelain(output)

      assert main.path == "/tmp/main"
      assert main.branch == "main"
      assert main.head == "abc123def456"
      assert main.detached == false
      assert main.bare == false
      assert main.locked == false

      assert feature.branch == "feature/foo"

      assert detached.branch == nil
      assert detached.detached == true
    end

    test "handles a bare and locked worktree" do
      output = """
      worktree /tmp/bare-repo
      bare

      worktree /tmp/locked
      HEAD abc123
      branch refs/heads/work
      locked some reason here
      """

      [bare, locked] = Data.parse_worktree_porcelain(output)

      assert bare.path == "/tmp/bare-repo"
      assert bare.bare == true

      assert locked.locked == true
      assert locked.branch == "work"
    end

    test "tolerates an empty output" do
      assert Data.parse_worktree_porcelain("") == []
    end

    test "skips malformed blocks (no worktree key)" do
      output = """
      something garbage
      HEAD abc

      worktree /tmp/real
      HEAD def
      branch refs/heads/main
      """

      assert [%{path: "/tmp/real"}] = Data.parse_worktree_porcelain(output)
    end
  end

  describe "subscribe_global_events/0" do
    test "is idempotent and returns :ok" do
      assert Data.subscribe_global_events() == :ok
      assert Data.subscribe_global_events() == :ok
      Data.unsubscribe_global_events()
    end
  end

  describe "pack_status/0" do
    test "always returns a status map even if PackParallelism is absent" do
      status = Data.pack_status()
      assert is_map(status)
      assert Map.has_key?(status, :limit)
      assert Map.has_key?(status, :active)
      assert Map.has_key?(status, :waiters)
      assert Map.has_key?(status, :available)
    end
  end

  describe "list_jobs/1" do
    test "returns a list (possibly empty) without raising" do
      jobs = Data.list_jobs()
      assert is_list(jobs)
    end

    test "filters by session_id" do
      # No active runs in test, so this should also be empty
      assert Data.list_jobs("nonexistent-session") == []
    end
  end

  describe "list_agents/0" do
    test "returns a list of agent maps with required keys" do
      agents = Data.list_agents()
      assert is_list(agents)

      for agent <- agents do
        assert is_binary(agent.name)
        assert is_binary(agent.display_name)
        assert is_binary(agent.description)
        assert is_integer(agent.active_runs) and agent.active_runs >= 0
      end
    end
  end

  describe "dashboard_summary/0" do
    test "returns a complete summary with all sections present" do
      summary = Data.dashboard_summary()

      assert is_map(summary.jobs)
      assert is_integer(summary.jobs.total)
      assert is_map(summary.jobs.by_status)
      assert is_list(summary.jobs.recent)

      assert is_map(summary.agents)
      assert is_integer(summary.agents.total)

      assert is_map(summary.sessions)
      assert is_map(summary.pack)
      assert is_map(summary.worktrees)
    end
  end

  describe "list_worktrees/1" do
    test "with a non-git directory returns []" do
      tmp =
        Path.join(System.tmp_dir!(), "admin_data_not_git_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert Data.list_worktrees(tmp) == []
    end
  end
end
