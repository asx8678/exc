defmodule CodePuppyControl.Pack.ConfigTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.Config

  # ── Default values ──────────────────────────────────────────────────────

  describe "load/0" do
    test "returns defaults when no config set" do
      # Ensure clean app env
      original = Application.get_env(:code_puppy_control, :distributed_packs)
      Application.delete_env(:code_puppy_control, :distributed_packs)

      config = Config.load()

      assert config.enabled == false
      assert config.node_name == nil
      assert config.cookie == nil
      assert config.workers == []
      assert config.connect_timeout == 5_000
      assert config.heartbeat_interval == 15_000
      assert config.disconnect_timeout == 30_000
      assert config.dispatch_style == :async
      assert config.sync_timeout == 30_000

      # Restore
      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "merges app env overrides with defaults" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      Application.put_env(:code_puppy_control, :distributed_packs, %{
        enabled: true,
        workers: [:"pup_w1@localhost"],
        cookie: :my_cookie
      })

      config = Config.load()

      assert config.enabled == true
      assert config.workers == [:"pup_w1@localhost"]
      assert config.cookie == :my_cookie
      # Defaults still present for unoverridden keys
      assert config.connect_timeout == 5_000
      assert config.heartbeat_interval == 15_000

      # Restore
      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      else
        Application.delete_env(:code_puppy_control, :distributed_packs)
      end
    end

    test "handles keyword list app env (normalizes to map)" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      Application.put_env(:code_puppy_control, :distributed_packs,
        enabled: true,
        workers: [:"pup_w1@host"]
      )

      config = Config.load()
      assert config.enabled == true
      assert config.workers == [:"pup_w1@host"]

      # Restore
      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      else
        Application.delete_env(:code_puppy_control, :distributed_packs)
      end
    end
  end

  describe "enabled?/0" do
    test "returns false by default" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)
      Application.delete_env(:code_puppy_control, :distributed_packs)

      assert Config.enabled?() == false

      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "returns true when configured as enabled" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true})
      assert Config.enabled?() == true

      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: "yes"})
      # Only explicit `true` enables — string "yes" does not
      assert Config.enabled?() == false

      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      else
        Application.delete_env(:code_puppy_control, :distributed_packs)
      end
    end
  end

  describe "workers/0" do
    test "returns empty list by default" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)
      Application.delete_env(:code_puppy_control, :distributed_packs)

      assert Config.workers() == []

      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "returns configured worker list" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      workers = [:"pup_w1@host1", :"pup_w2@host2"]
      Application.put_env(:code_puppy_control, :distributed_packs, %{workers: workers})

      assert Config.workers() == workers

      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      else
        Application.delete_env(:code_puppy_control, :distributed_packs)
      end
    end
  end

  describe "cookie/0" do
    test "returns nil by default" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)
      Application.delete_env(:code_puppy_control, :distributed_packs)

      assert Config.cookie() == nil

      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      end
    end

    test "returns configured cookie atom" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      Application.put_env(:code_puppy_control, :distributed_packs, %{cookie: :secret_cookie})
      assert Config.cookie() == :secret_cookie

      if original do
        Application.put_env(:code_puppy_control, :distributed_packs, original)
      else
        Application.delete_env(:code_puppy_control, :distributed_packs)
      end
    end
  end

  describe "defaults/0" do
    test "returns the default values map" do
      defaults = Config.defaults()

      assert is_map(defaults)
      assert defaults.enabled == false
      assert defaults.heartbeat_interval == 15_000
      assert Map.has_key?(defaults, :dispatch_style)
    end
  end
end
