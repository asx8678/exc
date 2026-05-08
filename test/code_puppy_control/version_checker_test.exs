defmodule CodePuppyControl.VersionCheckerTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.VersionChecker

  # We need async: false because we manipulate the filesystem cache and
  # environment variables (PUP_EX_HOME) for isolation.

  setup do
    # (code_puppy-i1n) PubSub must be alive for EventBus emission tests.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(CodePuppyControl.PubSub)

    # Isolate the cache directory via PUP_EX_HOME so we don't touch real
    # user state. Paths.cache_dir() respects PUP_EX_HOME.
    tmp = System.tmp_dir!() |> Path.join("vc_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original_home = System.get_env("PUP_EX_HOME")
    System.put_env("PUP_EX_HOME", tmp)

    on_exit(fn ->
      if original_home do
        System.put_env("PUP_EX_HOME", original_home)
      else
        System.delete_env("PUP_EX_HOME")
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  # ===========================================================================
  # normalize_version/1
  # ===========================================================================

  describe "normalize_version/1" do
    test "strips leading v" do
      assert VersionChecker.normalize_version("v1.2.3") == "1.2.3"
    end

    test "returns version unchanged when no leading v" do
      assert VersionChecker.normalize_version("1.2.3") == "1.2.3"
    end

    test "returns nil for nil" do
      assert VersionChecker.normalize_version(nil) == nil
    end

    test "returns empty string for empty string" do
      assert VersionChecker.normalize_version("") == ""
    end

    test "handles v-only prefix correctly" do
      assert VersionChecker.normalize_version("v") == ""
    end
  end

  # ===========================================================================
  # version_is_newer/2
  # ===========================================================================

  describe "version_is_newer/2" do
    test "1.2.3 is newer than 1.2.2" do
      assert VersionChecker.version_is_newer("1.2.3", "1.2.2")
    end

    test "v1.2.3 is NOT newer than 1.2.3 (same after normalization)" do
      refute VersionChecker.version_is_newer("v1.2.3", "1.2.3")
    end

    test "1.2.3 is NOT newer than itself" do
      refute VersionChecker.version_is_newer("1.2.3", "1.2.3")
    end

    test "1.10.0 is newer than 1.9.0 (integer comparison, not string)" do
      assert VersionChecker.version_is_newer("1.10.0", "1.9.0")
    end

    test "garbage is not newer than anything" do
      refute VersionChecker.version_is_newer("garbage", "1.0.0")
    end

    test "nil is not newer than anything" do
      refute VersionChecker.version_is_newer(nil, "1.0.0")
    end

    test "nothing is newer than nil" do
      refute VersionChecker.version_is_newer("1.0.0", nil)
    end

    test "major version bump" do
      assert VersionChecker.version_is_newer("2.0.0", "1.9.9")
    end

    test "minor version bump" do
      assert VersionChecker.version_is_newer("1.3.0", "1.2.9")
    end

    test "patch version bump" do
      assert VersionChecker.version_is_newer("1.2.4", "1.2.3")
    end
  end

  # ===========================================================================
  # versions_are_equal/2
  # ===========================================================================

  describe "versions_are_equal/2" do
    test "same versions are equal" do
      assert VersionChecker.versions_are_equal("1.2.3", "1.2.3")
    end

    test "v1.2.3 equals 1.2.3 after normalization" do
      assert VersionChecker.versions_are_equal("v1.2.3", "1.2.3")
    end

    test "different versions are not equal" do
      refute VersionChecker.versions_are_equal("1.2.3", "1.2.4")
    end

    test "garbage strings fall back to string equality" do
      assert VersionChecker.versions_are_equal("abc", "abc")
    end

    test "different garbage strings are not equal" do
      refute VersionChecker.versions_are_equal("abc", "def")
    end

    test "nil equals nil" do
      assert VersionChecker.versions_are_equal(nil, nil)
    end

    test "nil does not equal a version" do
      refute VersionChecker.versions_are_equal(nil, "1.0.0")
    end
  end

  # ===========================================================================
  # current_version/0
  # ===========================================================================

  describe "current_version/0" do
    test "returns a non-empty binary" do
      version = VersionChecker.current_version()
      assert is_binary(version)
      assert version != ""
    end

    test "matches semver-like pattern" do
      version = VersionChecker.current_version()
      assert Regex.match?(~r/^\d+\.\d+/, version)
    end
  end

  # ===========================================================================
  # Cache: write_cache / read_cache round-trip
  # ===========================================================================

  describe "cache round-trip" do
    test "writing then reading returns the cached version", %{tmp: _tmp} do
      # Ensure no stale cache
      path = VersionChecker.cache_path()
      File.rm(path)

      VersionChecker.write_cache("9.8.7")
      cache = VersionChecker.read_cache()

      assert %{"version" => "9.8.7"} = cache
      assert Map.has_key?(cache, "checked_at")
    end

    test "reading when file does not exist returns nil", %{tmp: _tmp} do
      path = VersionChecker.cache_path()
      File.rm(path)

      assert VersionChecker.read_cache() == nil
    end

    test "stale cache (older than 24h) is treated as miss", %{tmp: _tmp} do
      path = VersionChecker.cache_path()

      # Write a stale cache entry — checked_at is 48 hours ago
      stale_checked_at =
        DateTime.utc_now()
        |> DateTime.add(-48 * 3600, :second)
        |> DateTime.to_iso8601()

      stale_data = %{"version" => "0.0.1", "checked_at" => stale_checked_at}
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(stale_data))

      assert VersionChecker.read_cache() == nil
    end

    test "corrupt JSON returns nil", %{tmp: _tmp} do
      path = VersionChecker.cache_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json{{{")

      assert VersionChecker.read_cache() == nil
    end

    test "missing checked_at key returns nil", %{tmp: _tmp} do
      path = VersionChecker.cache_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"version" => "1.0.0"}))

      assert VersionChecker.read_cache() == nil
    end
  end

  # ===========================================================================
  # fetch_latest_version/1 — cache hit path
  # ===========================================================================

  describe "fetch_latest_version/1" do
    test "returns cached version when cache is fresh", %{tmp: _tmp} do
      path = VersionChecker.cache_path()
      File.rm(path)

      VersionChecker.write_cache("5.5.5")

      assert {:ok, "5.5.5"} = VersionChecker.fetch_latest_version()
    end

    test "returns error when cache is stale and no network (invalid URL)", %{tmp: _tmp} do
      path = VersionChecker.cache_path()
      File.rm(path)

      # Use a base_url that will fail — we just want to verify it doesn't
      # crash and returns an error tuple when there's no cache.
      result = VersionChecker.fetch_latest_version(base_url: "http://127.0.0.1:1/invalid")

      assert match?({:error, _}, result)
    end
  end

  # ===========================================================================
  # fetch_latest_version/1 — GitHub API integration (requires Bypass)
  # ===========================================================================

  describe "fetch_latest_version/1 — GitHub API integration" do
    @tag :skip
    test "fetches version from GitHub Releases API" do
      # Skipped: Bypass dependency not available.
      # To enable, add {:bypass, "~> 2.1"} to mix.exs test deps, then:
      #
      #   Bypass.open(fn conn ->
      #     assert conn.method == "GET"
      #     assert conn.request_path == "/repos/asx8678/code_puppy/releases/latest"
      #     Plug.Conn.resp(conn, 200, Jason.encode!(%{"tag_name" => "v9.9.9"}))
      #   end)
      #   url = "http://localhost:#{bypass.port}/repos/asx8678/code_puppy/releases/latest"
      #   assert {:ok, "9.9.9"} = VersionChecker.fetch_latest_version(base_url: url)
    end

    @tag :skip
    test "403 rate-limit returns {:error, :rate_limited}" do
      # Skipped: Bypass dependency not available.
      # To enable, add {:bypass, "~> 2.1"} to mix.exs test deps, then:
      #
      #   Bypass.open(fn conn ->
      #     conn
      #     |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      #     |> Plug.Conn.resp(403, "rate limited")
      #   end)
      #   url = "http://localhost:#{bypass.port}/repos/test/test/releases/latest"
      #   assert {:error, :rate_limited} = VersionChecker.fetch_latest_version(base_url: url)
    end
  end

  # ===========================================================================
  # default_version_mismatch_behavior/1 — EventBus emission
  # ===========================================================================

  describe "default_version_mismatch_behavior/1 — EventBus emission" do
    test "emits version_check event with update_available: true when cache has newer version",
         %{tmp: _tmp} do
      # Subscribe to global events
      :ok = CodePuppyControl.EventBus.subscribe_global()

      # Seed cache with a newer version
      path = VersionChecker.cache_path()
      File.rm(path)
      VersionChecker.write_cache("99.99.99")

      # Call with a low current version
      :ok = VersionChecker.default_version_mismatch_behavior("0.0.1")

      # Should receive a version_check event
      assert_received {:event,
                       %{
                         type: "version_check",
                         current_version: "0.0.1",
                         latest_version: "99.99.99",
                         update_available: true
                       }}

      # Clean up subscription
      CodePuppyControl.EventBus.unsubscribe_global()
    end

    test "emits version_check event with update_available: false when versions match",
         %{tmp: _tmp} do
      :ok = CodePuppyControl.EventBus.subscribe_global()

      path = VersionChecker.cache_path()
      File.rm(path)
      VersionChecker.write_cache("1.0.0")

      :ok = VersionChecker.default_version_mismatch_behavior("1.0.0")

      assert_received {:event,
                       %{
                         type: "version_check",
                         current_version: "1.0.0",
                         latest_version: "1.0.0",
                         update_available: false
                       }}

      CodePuppyControl.EventBus.unsubscribe_global()
    end

    test "emits current-only event on cache miss", %{tmp: _tmp} do
      :ok = CodePuppyControl.EventBus.subscribe_global()

      # Remove cache
      path = VersionChecker.cache_path()
      File.rm(path)

      :ok = VersionChecker.default_version_mismatch_behavior("1.0.0")

      assert_received {:event,
                       %{
                         type: "version_check",
                         current_version: "1.0.0",
                         latest_version: "1.0.0",
                         update_available: false,
                         release_url: nil
                       }}

      CodePuppyControl.EventBus.unsubscribe_global()
    end

    test "nil current version defaults to 0.0.0-unknown", %{tmp: _tmp} do
      :ok = CodePuppyControl.EventBus.subscribe_global()

      # Remove cache to trigger current-only path
      path = VersionChecker.cache_path()
      File.rm(path)

      :ok = VersionChecker.default_version_mismatch_behavior(nil)

      assert_received {:event,
                       %{
                         type: "version_check",
                         current_version: "0.0.0-unknown"
                       }}

      CodePuppyControl.EventBus.unsubscribe_global()
    end
  end
end
