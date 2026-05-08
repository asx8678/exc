defmodule CodePuppyControl.Config.CacheTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Cache, Loader}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "cache_test_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    File.write!(@test_cfg, "[puppy]\n")
    Loader.load(@test_cfg)

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
    end)

    :ok
  end

  describe "frontend_emitter_enabled?/0" do
    test "defaults to true" do
      assert Cache.frontend_emitter_enabled?() == true
    end

    test "respects config" do
      File.write!(@test_cfg, "[puppy]\nfrontend_emitter_enabled = false\n")
      Loader.load(@test_cfg)

      assert Cache.frontend_emitter_enabled?() == false
    end
  end

  describe "frontend_emitter_max_recent_events/0" do
    test "defaults to 100" do
      assert Cache.frontend_emitter_max_recent_events() == 100
    end
  end

  describe "frontend_emitter_queue_size/0" do
    test "defaults to 100" do
      assert Cache.frontend_emitter_queue_size() == 100
    end
  end

  describe "ws_history_maxlen/0" do
    test "defaults to 200" do
      assert Cache.ws_history_maxlen() == 200
    end

    test "reads configured value" do
      File.write!(@test_cfg, "[puppy]\nws_history_maxlen = 500\n")
      Loader.load(@test_cfg)

      assert Cache.ws_history_maxlen() == 500
    end
  end

  describe "ws_history_ttl_seconds/0" do
    test "defaults to 3600" do
      assert Cache.ws_history_ttl_seconds() == 3600
    end

    test "reads configured value" do
      File.write!(@test_cfg, "[puppy]\nws_history_ttl_seconds = 7200\n")
      Loader.load(@test_cfg)

      assert Cache.ws_history_ttl_seconds() == 7200
    end

    test "allows 0 to disable" do
      File.write!(@test_cfg, "[puppy]\nws_history_ttl_seconds = 0\n")
      Loader.load(@test_cfg)

      assert Cache.ws_history_ttl_seconds() == 0
    end
  end
end
