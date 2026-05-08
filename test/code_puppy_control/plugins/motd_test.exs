defmodule CodePuppyControl.Plugins.MotdTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.{Callbacks, Plugins}
  alias CodePuppyControl.Plugins.Motd

  setup do
    Callbacks.clear()
    Motd.reset()
    :ok
  end

  describe "name/0" do
    test "returns string identifier" do
      assert Motd.name() == "motd"
    end
  end

  describe "description/0" do
    test "returns a non-empty description" do
      assert Motd.description() != ""
      assert is_binary(Motd.description())
    end
  end

  describe "register/0" do
    test "registers :get_motd and :startup callbacks" do
      assert :ok = Motd.register()

      # Should have callbacks for :get_motd and :startup
      assert Callbacks.count_callbacks(:get_motd) >= 1
      assert Callbacks.count_callbacks(:startup) >= 1
    end
  end

  describe "get_motd/0" do
    test "returns a list of {title, body} tuples" do
      results = Motd.get_motd()
      assert is_list(results)
      assert length(results) >= 1

      {title, body} = hd(results)
      assert is_binary(title)
      assert is_binary(body)
    end

    test "body contains version info" do
      [{_title, body}] = Motd.get_motd()
      assert body =~ "Code Puppy"
    end
  end

  describe "startup/0" do
    test "marks MOTD as shown" do
      Motd.startup()
      assert Motd.motd_shown?() == true
    end

    test "idempotent — calling twice is safe" do
      Motd.startup()
      Motd.startup()
      assert Motd.motd_shown?() == true
    end
  end

  describe "shutdown/0" do
    test "clears MOTD shown state" do
      Motd.startup()
      assert Motd.motd_shown?() == true

      Motd.shutdown()
      assert Motd.motd_shown?() == false
    end
  end

  describe "loading via Plugins API" do
    test "can be loaded and triggered through the plugin system" do
      Plugins.load_plugin(Motd)

      # Trigger :get_motd through the callback system
      # :get_motd has :extend_list merge — result is a list of {title, body} tuples
      results = Callbacks.trigger(:get_motd)
      assert is_list(results)
      assert length(results) >= 1

      {title, body} = hd(results)
      assert is_binary(title)
      assert is_binary(body)
      assert body =~ "Code Puppy"
    end
  end

  describe "reset/0" do
    test "clears internal state for test isolation" do
      Motd.startup()
      assert Motd.motd_shown?() == true

      Motd.reset()
      assert Motd.motd_shown?() == false
    end
  end
end
