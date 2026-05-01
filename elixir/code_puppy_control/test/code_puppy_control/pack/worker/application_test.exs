defmodule CodePuppyControl.Pack.Worker.ApplicationTest do
  @moduledoc """
  Tests for Pack.Worker.Application — the lightweight OTP app for worker nodes.

  These tests exercise the public API (children/1, worker_config/1,
  worker_mode?/0, start_worker/1 validation) **without** starting real
  Erlang distribution or booting the full supervision tree.

  Tagged `:distributed` for CI filtering.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed

  alias CodePuppyControl.Pack.Worker.Application, as: WorkerApp

  @leader_node :test_leader@localhost

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    # Ensure worker mode is cleared between tests
    Application.put_env(:code_puppy_control, :pack_worker_mode, false)

    on_exit(fn ->
      Application.put_env(:code_puppy_control, :pack_worker_mode, false)
    end)

    :ok
  end

  # ── worker_mode?/0 ──────────────────────────────────────────────────────

  describe "worker_mode?/0" do
    test "returns false by default" do
      refute WorkerApp.worker_mode?()
    end

    test "returns true when application env is set" do
      Application.put_env(:code_puppy_control, :pack_worker_mode, true)
      assert WorkerApp.worker_mode?()
    end

    test "returns false after being reset" do
      Application.put_env(:code_puppy_control, :pack_worker_mode, true)
      assert WorkerApp.worker_mode?()

      Application.put_env(:code_puppy_control, :pack_worker_mode, false)
      refute WorkerApp.worker_mode?()
    end
  end

  # ── children/1 ──────────────────────────────────────────────────────────

  describe "children/1" do
    test "returns a non-empty list of child specs" do
      children = WorkerApp.children(leader: @leader_node)
      assert is_list(children)
      assert length(children) >= 8
    end

    test "includes expected modules in the child specs" do
      children = WorkerApp.children(leader: @leader_node)

      # Extract module names from child specs (handles various spec shapes)
      child_ids = Enum.map(children, &extract_child_id/1)

      assert CodePuppyControl.HttpClient in child_ids or
               Finch in child_ids,
             "should include HttpClient/Finch: #{inspect(child_ids)}"

      assert Phoenix.PubSub in child_ids,
             "should include PubSub: #{inspect(child_ids)}"

      assert CodePuppyControl.Pack.Registries in child_ids,
             "should include Pack.Registries: #{inspect(child_ids)}"

      assert CodePuppyControl.Pack.NamingService in child_ids,
             "should include NamingService: #{inspect(child_ids)}"

      assert CodePuppyControl.ModelRegistry in child_ids,
             "should include ModelRegistry: #{inspect(child_ids)}"

      assert CodePuppyControl.Pack.Worker in child_ids,
             "should include Pack.Worker: #{inspect(child_ids)}"

      assert CodePuppyControl.Pack.NodeMonitor in child_ids,
             "should include NodeMonitor: #{inspect(child_ids)}"

      assert CodePuppyControl.Concurrency.Supervisor in child_ids,
             "should include Concurrency.Supervisor: #{inspect(child_ids)}"
    end

    test "does NOT include main-app-only services" do
      children = WorkerApp.children(leader: @leader_node)
      child_ids = Enum.map(children, &extract_child_id/1)

      excluded = [
        CodePuppyControlWeb.Endpoint,
        CodePuppyControl.Repo,
        CodePuppyControl.SessionStorage.Store,
        CodePuppyControl.PolicyEngine,
        CodePuppyControl.Callbacks.Registry,
        CodePuppyControl.Config.Writer,
        CodePuppyControl.FeatureFlags,
        CodePuppyControl.HookEngine
      ]

      for mod <- excluded do
        refute mod in child_ids,
               "worker should NOT include #{inspect(mod)}"
      end
    end

    test "passes worker opts to Pack.Worker child spec" do
      children = WorkerApp.children(leader: @leader_node, max_concurrent_runs: 5)
      worker_spec = find_child(children, CodePuppyControl.Pack.Worker)
      assert worker_spec, "Pack.Worker child spec not found"

      # The tuple form {Module, opts} should pass max_concurrent_runs
      {_mod, opts} = worker_spec
      assert opts[:max_concurrent_runs] == 5
    end

    test "configures NodeMonitor with leader as watched worker" do
      children = WorkerApp.children(leader: @leader_node)
      monitor_spec = find_child(children, CodePuppyControl.Pack.NodeMonitor)
      assert monitor_spec, "NodeMonitor child spec not found"

      {_mod, opts} = monitor_spec
      assert opts[:enabled] == true
      assert Atom.to_string(@leader_node) in opts[:workers]
    end

    test "NodeMonitor disabled when no leader specified" do
      children = WorkerApp.children([])
      monitor_spec = find_child(children, CodePuppyControl.Pack.NodeMonitor)
      assert monitor_spec, "NodeMonitor child spec not found"

      {_mod, opts} = monitor_spec
      assert opts[:enabled] == false
    end

    test "worker child spec uses leader-protocol-compatible name" do
      children = WorkerApp.children(leader: @leader_node)

      worker_spec =
        Enum.find(children, fn
          {CodePuppyControl.Pack.Worker, _opts} -> true
          _ -> false
        end)

      {_, opts} = worker_spec
      assert opts[:name] == :pack_worker
    end
  end

  # ── worker_config/1 ─────────────────────────────────────────────────────

  describe "worker_config/1" do
    test "explicit opts take precedence" do
      config =
        WorkerApp.worker_config(
          leader: @leader_node,
          cookie: "secret",
          max_concurrent_runs: 8,
          available_models: ["gpt-4"]
        )

      assert config[:leader] == @leader_node
      assert config[:cookie] == "secret"
      assert config[:max_concurrent_runs] == 8
      assert config[:available_models] == ["gpt-4"]
    end

    test "defaults when no opts and no puppy.cfg section" do
      config = WorkerApp.worker_config([])

      # No leader configured — nil
      assert config[:leader] == nil
      assert config[:cookie] == nil
      assert config[:max_concurrent_runs] == 2
      # available_models is omitted when not explicitly provided,
      # letting Capabilities.detect/1 auto-discover from ModelRegistry
      refute Keyword.has_key?(config, :available_models)
    end

    test "string leader is converted to atom" do
      config = WorkerApp.worker_config(leader: "pup_leader@some_host")
      assert config[:leader] == :pup_leader@some_host
    end

    test "atom leader is kept as-is" do
      config = WorkerApp.worker_config(leader: :pup_leader@some_host)
      assert config[:leader] == :pup_leader@some_host
    end

    test "invalid max_concurrent_runs falls back to default" do
      config = WorkerApp.worker_config(leader: @leader_node, max_concurrent_runs: -1)
      assert config[:max_concurrent_runs] == 2
    end

    test "zero max_concurrent_runs falls back to default" do
      config = WorkerApp.worker_config(leader: @leader_node, max_concurrent_runs: 0)
      assert config[:max_concurrent_runs] == 2
    end
  end

  # ── start_worker/1 validation ───────────────────────────────────────────

  describe "start_worker/1 validation" do
    test "returns error when leader is missing" do
      assert {:error, :missing_leader} = WorkerApp.start_worker([])
    end

    test "returns error when leader is missing from empty opts" do
      assert {:error, :missing_leader} = WorkerApp.start_worker(cookie: "abc")
    end

    test "does not set worker_mode when validation fails" do
      refute WorkerApp.worker_mode?()
      {:error, :missing_leader} = WorkerApp.start_worker([])
      refute WorkerApp.worker_mode?()
    end

    test "start_worker/1 exercises full startup path including dependency check" do
      # Trap exits: start_worker/1 uses Supervisor.start_link, which links
      # to the caller. In test env, named child processes may already be
      # running, causing a supervisor init failure that sends an EXIT.
      Process.flag(:trap_exit, true)

      result = WorkerApp.start_worker(leader: @leader_node)

      case result do
        {:ok, pid} ->
          # Full startup succeeded
          assert Process.alive?(pid)
          assert WorkerApp.worker_mode?()
          Supervisor.stop(pid)

        {:error, reason} ->
          # The with-chain passed ensure_required_apps_started/0 — if it
          # had failed we'd see {:error, {:dependency_start_failed, _, _}}.
          # Instead, the supervisor hit a name conflict (expected in test env).
          refute match?({:dependency_start_failed, _, _}, reason),
                 "Expected to get past ensure_required_apps_started/0, got: #{inspect(reason)}"
      end

      Application.put_env(:code_puppy_control, :pack_worker_mode, false)
    end

    test "ensure_required_apps_started/0 succeeds when deps available" do
      assert :ok = WorkerApp.ensure_required_apps_started()
    end
  end

  # ── OTP Application callbacks ───────────────────────────────────────────

  describe "stop/1" do
    test "clears the worker mode flag" do
      Application.put_env(:code_puppy_control, :pack_worker_mode, true)
      assert WorkerApp.worker_mode?()

      WorkerApp.stop([])
      refute WorkerApp.worker_mode?()
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Extracts a child ID from various child spec shapes.
  # Handles: module atoms, {Module, opts} tuples, and %{id: _} maps.
  defp extract_child_id(%{id: id}), do: id
  defp extract_child_id({mod, _opts}) when is_atom(mod), do: mod
  defp extract_child_id(mod) when is_atom(mod), do: mod

  defp extract_child_id(other) do
    # Try to normalize via Supervisor.child_spec/2
    try do
      spec = Supervisor.child_spec(other, [])
      spec.id
    rescue
      _ -> other
    end
  end

  # Finds a child spec matching the given module (as ID or first tuple element).
  defp find_child(children, target_mod) do
    Enum.find(children, fn
      {^target_mod, _opts} -> true
      ^target_mod -> true
      %{id: ^target_mod} -> true
      _ -> false
    end)
  end
end
