defmodule CodePuppyControl.Pack.Worker.CapabilitiesTest do
  use ExUnit.Case, async: true

  @moduletag :distributed

  alias CodePuppyControl.Pack.Worker.Capabilities

  @required_keys [
    :host_os,
    :sub_agents,
    :available_models,
    :max_concurrent_runs,
    :beam_version,
    :node_name,
    :started_at
  ]

  describe "detect/0" do
    test "returns all required keys" do
      caps = Capabilities.detect()

      for key <- @required_keys do
        assert Map.has_key?(caps, key), "missing key: #{inspect(key)}"
      end
    end

    test "host_os is a valid string" do
      caps = Capabilities.detect()

      assert is_binary(caps.host_os)
      assert caps.host_os in ["darwin", "linux", "windows", "macos", "unknown"]
    end

    test "sub_agents is a non-empty list of atoms" do
      caps = Capabilities.detect()

      assert is_list(caps.sub_agents)
      assert length(caps.sub_agents) > 0
      assert Enum.all?(caps.sub_agents, &is_atom/1)
    end

    test "available_models is a list" do
      caps = Capabilities.detect()

      assert is_list(caps.available_models)
    end

    test "max_concurrent_runs is a positive integer capped at 4" do
      caps = Capabilities.detect()

      assert is_integer(caps.max_concurrent_runs)
      assert caps.max_concurrent_runs >= 1
      assert caps.max_concurrent_runs <= 4
    end

    test "beam_version is a non-empty string" do
      caps = Capabilities.detect()

      assert is_binary(caps.beam_version)
      assert caps.beam_version != ""
    end

    test "node_name returns the current node" do
      caps = Capabilities.detect()

      assert caps.node_name == Node.self()
    end

    test "started_at is a UTC DateTime" do
      before = DateTime.utc_now()
      caps = Capabilities.detect()
      after_detect = DateTime.utc_now()

      assert %DateTime{} = caps.started_at
      assert DateTime.compare(caps.started_at, before) in [:eq, :gt]
      assert DateTime.compare(caps.started_at, after_detect) in [:eq, :lt]
    end
  end

  describe "detect/1 with overrides" do
    test "host_os override as atom is stringified" do
      caps = Capabilities.detect(host_os: :linux)
      assert caps.host_os == "linux"
    end

    test "host_os override as string is preserved" do
      caps = Capabilities.detect(host_os: "freebsd")
      assert caps.host_os == "freebsd"
    end

    test "sub_agents override replaces discovery" do
      custom = [:alpha, :bravo]
      caps = Capabilities.detect(sub_agents: custom)
      assert caps.sub_agents == custom
    end

    test "available_models override replaces discovery" do
      models = ["model-a", "model-b"]
      caps = Capabilities.detect(available_models: models)
      assert caps.available_models == models
    end

    test "available_models empty list override is respected" do
      caps = Capabilities.detect(available_models: [])
      assert caps.available_models == []
    end

    test "max_concurrent_runs override is respected" do
      caps = Capabilities.detect(max_concurrent_runs: 8)
      assert caps.max_concurrent_runs == 8
    end

    test "max_concurrent_runs must be positive" do
      caps = Capabilities.detect(max_concurrent_runs: 0)
      # Falls through to scheduler-based default
      assert caps.max_concurrent_runs >= 1
    end

    test "negative max_concurrent_runs falls back to default" do
      caps = Capabilities.detect(max_concurrent_runs: -1)
      assert caps.max_concurrent_runs >= 1
      assert caps.max_concurrent_runs <= 4
    end

    test "unrelated keys in overrides are ignored" do
      caps = Capabilities.detect(host_os: :linux, bogus_key: "whatever")
      assert caps.host_os == "linux"
      refute Map.has_key?(caps, :bogus_key)
    end

    test "beam_version cannot be overridden" do
      # beam_version is always from the runtime — overrides are ignored
      caps = Capabilities.detect(beam_version: "fake")
      assert caps.beam_version != "fake"
      assert is_binary(caps.beam_version)
    end

    test "node_name cannot be overridden" do
      caps = Capabilities.detect(node_name: :fake@node)
      assert caps.node_name == Node.self()
    end

    test "started_at cannot be overridden" do
      fake = ~U[2000-01-01 00:00:00Z]
      caps = Capabilities.detect(started_at: fake)
      assert DateTime.compare(caps.started_at, fake) == :gt
    end
  end

  describe "graceful fallbacks" do
    test "sub_agents falls back to defaults when AgentCatalogue is unavailable" do
      # AgentCatalogue is not running in test env → should get defaults
      caps = Capabilities.detect()

      assert :terrier in caps.sub_agents
      assert :watchdog in caps.sub_agents
      assert :shepherd in caps.sub_agents
      assert :retriever in caps.sub_agents
    end

    test "host_os falls back to system detection for invalid override types" do
      caps = Capabilities.detect(host_os: 42)
      assert is_binary(caps.host_os)
      assert caps.host_os in ["darwin", "linux", "windows", "unknown"]
    end

    test "available_models falls back to empty list when ModelRegistry is unavailable" do
      # ModelRegistry may not be running → should get []
      # (If it IS running, we still get a list — either way, no crash)
      caps = Capabilities.detect()
      assert is_list(caps.available_models)
    end
  end
end
