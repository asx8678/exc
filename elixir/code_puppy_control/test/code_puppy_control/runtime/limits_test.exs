defmodule CodePuppyControl.Runtime.LimitsTest do
  @moduledoc """
  Tests for CodePuppyControl.Runtime.Limits — centralized runtime concurrency caps.

  Validates resolution order (env var > app config > profile defaults),
  profile switching, invalid value handling, and the all/0 report.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Runtime.Limits

  # All env vars this module reads
  @all_env_vars [
    "PUP_PROFILE",
    "PUP_MAX_PYTHON_WORKERS",
    "PUP_MAX_MCP_SERVERS",
    "PUP_MAX_MCP_CLIENTS",
    "PUP_MAX_RUNS",
    "PUP_MAX_AGENT_STATES",
    "PUP_MAX_PTY_SESSIONS",
    "PUP_CPU_CONCURRENCY",
    "PUP_IO_CONCURRENCY",
    "PUP_FINCH_POOL_COUNT",
    "PUP_FINCH_POOL_SIZE"
  ]

  setup do
    # Capture original env vars so we can restore them
    original =
      Map.new(@all_env_vars, fn var -> {var, System.get_env(var)} end)

    original_app_env = Application.get_env(:code_puppy_control, :limits)

    on_exit(fn ->
      # Restore env vars
      Enum.each(original, fn
        {var, nil} -> System.delete_env(var)
        {var, val} -> System.put_env(var, val)
      end)

      # Restore app env
      if original_app_env do
        Application.put_env(:code_puppy_control, :limits, original_app_env)
      else
        Application.delete_env(:code_puppy_control, :limits)
      end
    end)

    # Start each test with a clean slate
    Enum.each(@all_env_vars, &System.delete_env/1)
    Application.delete_env(:code_puppy_control, :limits)

    :ok
  end

  # ── Default (laptop) Profile ─────────────────────────────────────────────

  describe "default (:laptop) profile" do
    test "max_mcp_servers defaults to 12" do
      assert Limits.max_mcp_servers() == 12
    end

    test "max_mcp_clients defaults to 12" do
      assert Limits.max_mcp_clients() == 12
    end

    test "max_runs defaults to 12" do
      assert Limits.max_runs() == 12
    end

    test "max_agent_states defaults to 256" do
      assert Limits.max_agent_states() == 256
    end

    test "max_pty_sessions defaults to 6" do
      assert Limits.max_pty_sessions() == 6
    end

    test "cpu_concurrency defaults to 4" do
      assert Limits.cpu_concurrency() == 4
    end

    test "io_concurrency defaults to 3" do
      assert Limits.io_concurrency() == 3
    end

    test "finch_pool_count defaults to 4" do
      assert Limits.finch_pool_count() == 4
    end

    test "finch_pool_size defaults to 25" do
      assert Limits.finch_pool_size() == 25
    end

    test "profile returns :laptop" do
      assert Limits.profile() == :laptop
    end
  end

  # ── Desktop Profile ──────────────────────────────────────────────────────

  describe ":desktop profile" do
    setup do
      System.put_env("PUP_PROFILE", "desktop")
      :ok
    end

    test "switches all defaults to desktop values" do
      assert Limits.max_mcp_servers() == 24
      assert Limits.max_mcp_clients() == 24
      assert Limits.max_runs() == 24
      assert Limits.max_agent_states() == 512
      assert Limits.max_pty_sessions() == 12
      assert Limits.cpu_concurrency() == 8
      assert Limits.io_concurrency() == 6
      assert Limits.finch_pool_count() == 8
      assert Limits.finch_pool_size() == 50
      assert Limits.profile() == :desktop
    end
  end

  # ── Server Profile ───────────────────────────────────────────────────────

  describe ":server profile" do
    setup do
      System.put_env("PUP_PROFILE", "server")
      :ok
    end

    test "switches all defaults to server values" do
      schedulers = System.schedulers_online()

      assert Limits.max_mcp_servers() == 48
      assert Limits.max_mcp_clients() == 48
      assert Limits.max_runs() == 48
      assert Limits.max_agent_states() == 1024
      assert Limits.max_pty_sessions() == 24
      assert Limits.cpu_concurrency() == schedulers
      assert Limits.io_concurrency() == 12
      assert Limits.finch_pool_count() == schedulers
      assert Limits.finch_pool_size() == 50
      assert Limits.profile() == :server
    end
  end

  # ── Per-key Env Var Override ──────────────────────────────────────────────

  describe "per-key env var override" do
    test "PUP_CPU_CONCURRENCY beats profile default" do
      System.put_env("PUP_CPU_CONCURRENCY", "16")
      assert Limits.cpu_concurrency() == 16
    end

    test "PUP_FINCH_POOL_COUNT beats profile default" do
      System.put_env("PUP_FINCH_POOL_COUNT", "2")
      assert Limits.finch_pool_count() == 2
    end

    test "PUP_FINCH_POOL_SIZE beats profile default" do
      System.put_env("PUP_FINCH_POOL_SIZE", "10")
      assert Limits.finch_pool_size() == 10
    end

    test "env var beats desktop profile when both set" do
      System.put_env("PUP_PROFILE", "desktop")
      System.put_env("PUP_MAX_RUNS", "7")
      assert Limits.max_runs() == 7
    end
  end

  # ── Application Config Override ──────────────────────────────────────────

  describe "Application config override" do
    test "app config beats profile default but loses to env var" do
      Application.put_env(:code_puppy_control, :limits, max_runs: 42)
      assert Limits.max_runs() == 42

      # Env var wins over app config
      System.put_env("PUP_MAX_RUNS", "7")
      assert Limits.max_runs() == 7
    end

    test "app config works for cpu_concurrency" do
      Application.put_env(:code_puppy_control, :limits, cpu_concurrency: 2)
      assert Limits.cpu_concurrency() == 2
    end

    test "invalid app config value falls through to profile default" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Application.put_env(:code_puppy_control, :limits, max_runs: -5)
          # Falls through to laptop default
          assert Limits.max_runs() == 12
        end)

      assert log =~ "is invalid"
    end
  end

  # ── Invalid Env Var Handling ─────────────────────────────────────────────

  describe "invalid env var values" do
    test "non-integer PUP_CPU_CONCURRENCY logs warning and falls through" do
      System.put_env("PUP_CPU_CONCURRENCY", "abc")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Falls through to laptop default of 4
          assert Limits.cpu_concurrency() == 4
        end)

      assert log =~ "not a valid integer"
    end

    test "negative PUP_CPU_CONCURRENCY falls through" do
      System.put_env("PUP_CPU_CONCURRENCY", "-1")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Falls through to laptop default of 4
          assert Limits.cpu_concurrency() == 4
        end)

      assert log =~ "< 1"
    end

    test "zero PUP_IO_CONCURRENCY falls through" do
      System.put_env("PUP_IO_CONCURRENCY", "0")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Falls through to laptop default of 3
          assert Limits.io_concurrency() == 3
        end)

      assert log =~ "< 1"
    end
  end

  # ── all/0 ─────────────────────────────────────────────────────────────────

  describe "all/0" do
    test "returns map with all 10 keys" do
      result = Limits.all()

      assert Map.has_key?(result, :profile)
      assert Map.has_key?(result, :max_mcp_servers)
      assert Map.has_key?(result, :max_mcp_clients)
      assert Map.has_key?(result, :max_runs)
      assert Map.has_key?(result, :max_agent_states)
      assert Map.has_key?(result, :max_pty_sessions)
      assert Map.has_key?(result, :cpu_concurrency)
      assert Map.has_key?(result, :io_concurrency)
      assert Map.has_key?(result, :finch_pool_count)
      assert Map.has_key?(result, :finch_pool_size)

      # 9 limit keys + :profile = 10 keys
      assert map_size(result) == 10
    end

    test "all values are positive integers (except :profile atom)" do
      result = Limits.all()

      for key <- [
            :max_mcp_servers,
            :max_mcp_clients,
            :max_runs,
            :max_agent_states,
            :max_pty_sessions,
            :cpu_concurrency,
            :io_concurrency,
            :finch_pool_count,
            :finch_pool_size
          ] do
        assert is_integer(result[key]) and result[key] >= 1,
               "Expected #{key} to be a positive integer, got: #{inspect(result[key])}"
      end

      assert result[:profile] in [:laptop, :desktop, :server]
    end
  end

  # ── report/0 ──────────────────────────────────────────────────────────────

  describe "report/0" do
    test "returns :ok and prints to stdout" do
      # Owl.IO.puts writes to stdout; capture it to avoid polluting test output
      _output =
        ExUnit.CaptureIO.capture_io(fn ->
          result = Limits.report()
          assert result == :ok
        end)
    end
  end
end
