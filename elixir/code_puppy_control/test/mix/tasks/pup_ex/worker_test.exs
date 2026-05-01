defmodule Mix.Tasks.PupEx.WorkerTest do
  @moduledoc """
  Unit tests for `mix pup_ex.worker` CLI arg parsing and validation.

  Tests the parsing layer and option validation WITHOUT starting
  real Erlang distribution or the worker supervision tree.

  Refs: code_puppy-4s2.2
  """

  use ExUnit.Case, async: true

  @moduletag :distributed

  alias Mix.Tasks.PupEx.Worker

  describe "parse_args/1" do
    test "parses --sname flag" do
      assert {:ok, opts} = Worker.parse_args(["--sname", "worker_01"])
      assert opts[:sname] == "worker_01"
    end

    test "parses -s alias for --sname" do
      assert {:ok, opts} = Worker.parse_args(["-s", "worker_01"])
      assert opts[:sname] == "worker_01"
    end

    test "parses --name flag" do
      assert {:ok, opts} = Worker.parse_args(["--name", "worker_01@192.168.1.10"])
      assert opts[:name] == "worker_01@192.168.1.10"
    end

    test "parses -n alias for --name" do
      assert {:ok, opts} = Worker.parse_args(["-n", "worker_01@10.0.0.5"])
      assert opts[:name] == "worker_01@10.0.0.5"
    end

    test "parses --cookie flag" do
      assert {:ok, opts} = Worker.parse_args(["--cookie", "secret_cookie"])
      assert opts[:cookie] == "secret_cookie"
    end

    test "parses -c alias for --cookie" do
      assert {:ok, opts} = Worker.parse_args(["-c", "my_cookie"])
      assert opts[:cookie] == "my_cookie"
    end

    test "parses --leader flag" do
      assert {:ok, opts} = Worker.parse_args(["--leader", "leader@host"])
      assert opts[:leader] == "leader@host"
    end

    test "parses -l alias for --leader" do
      assert {:ok, opts} = Worker.parse_args(["-l", "leader@host"])
      assert opts[:leader] == "leader@host"
    end

    test "parses --max-concurrent-runs flag" do
      assert {:ok, opts} = Worker.parse_args(["--max-concurrent-runs", "4"])
      assert opts[:max_concurrent_runs] == 4
    end

    test "parses -m alias for --max-concurrent-runs" do
      assert {:ok, opts} = Worker.parse_args(["-m", "8"])
      assert opts[:max_concurrent_runs] == 8
    end

    test "parses all flags together" do
      args = [
        "--sname",
        "worker_01",
        "--cookie",
        "s3cr3t",
        "--leader",
        "leader@host",
        "-m",
        "4"
      ]

      assert {:ok, opts} = Worker.parse_args(args)
      assert opts[:sname] == "worker_01"
      assert opts[:cookie] == "s3cr3t"
      assert opts[:leader] == "leader@host"
      assert opts[:max_concurrent_runs] == 4
    end

    test "returns :help for --help flag" do
      assert :help = Worker.parse_args(["--help"])
    end

    test "returns :help for -h alias" do
      assert :help = Worker.parse_args(["-h"])
    end

    test "returns error for unknown flags" do
      assert {:error, message} = Worker.parse_args(["--bogus", "value"])
      assert message =~ "invalid flag"
    end

    test "returns error for positional arguments" do
      assert {:error, message} = Worker.parse_args(["some_random_arg"])
      assert message =~ "unexpected positional"
    end

    test "accepts empty args (will read from puppy.cfg)" do
      assert {:ok, []} = Worker.parse_args([])
    end
  end

  describe "validate_opts/1 — name exclusivity" do
    test "rejects --sname and --name together" do
      opts = [sname: "worker_01", name: "worker_01@host"]
      assert {:error, message} = Worker.validate_opts(opts)
      assert message =~ "mutually exclusive"
    end

    test "accepts --sname alone" do
      assert {:ok, _opts} = Worker.validate_opts(sname: "worker_01")
    end

    test "accepts --name alone" do
      assert {:ok, _opts} = Worker.validate_opts(name: "worker_01@host")
    end

    test "accepts neither --sname nor --name (config-only mode)" do
      assert {:ok, _opts} = Worker.validate_opts(leader: "leader@host")
    end
  end

  describe "validate_opts/1 — max_concurrent_runs" do
    test "accepts positive integer" do
      assert {:ok, _opts} = Worker.validate_opts(max_concurrent_runs: 4)
    end

    test "rejects zero" do
      assert {:error, message} = Worker.validate_opts(max_concurrent_runs: 0)
      assert message =~ "positive integer"
    end

    test "rejects negative values" do
      assert {:error, message} = Worker.validate_opts(max_concurrent_runs: -1)
      assert message =~ "positive integer"
    end

    test "accepts when not provided (uses default)" do
      assert {:ok, _opts} = Worker.validate_opts([])
    end
  end

  describe "build_worker_opts/1" do
    test "converts leader string to atom" do
      opts = [leader: "leader@host", cookie: "secret", max_concurrent_runs: 4]
      result = Worker.build_worker_opts(opts)

      assert result[:leader] == :"leader@host"
      assert result[:cookie] == "secret"
      assert result[:max_concurrent_runs] == 4
    end

    test "omits keys not provided" do
      result = Worker.build_worker_opts([])

      refute Keyword.has_key?(result, :leader)
      refute Keyword.has_key?(result, :cookie)
      refute Keyword.has_key?(result, :max_concurrent_runs)
    end

    test "includes only provided keys" do
      result = Worker.build_worker_opts(leader: "my_leader@host")

      assert result[:leader] == :"my_leader@host"
      refute Keyword.has_key?(result, :cookie)
      refute Keyword.has_key?(result, :max_concurrent_runs)
    end
  end

  describe "start_distribution/1" do
    test "returns :ok when no name flags provided and node not alive" do
      # Without --sname or --name, the task trusts the user already started
      # distribution (or is running from puppy.cfg)
      assert :ok = Worker.start_distribution([])
    end
  end
end
