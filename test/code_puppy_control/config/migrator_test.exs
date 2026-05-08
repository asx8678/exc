defmodule CodePuppyControl.Config.MigratorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Loader, Migrator, Writer}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "migrator_test_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    Loader.invalidate()

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
    end)

    :ok
  end

  describe "current_version/0" do
    test "returns 0 when no schema_version key" do
      File.write!(@test_cfg, "[puppy]\nmodel = test\n")
      Loader.load(@test_cfg)

      assert Migrator.current_version() == 0
    end

    test "reads schema_version from config" do
      File.write!(@test_cfg, "[puppy]\nschema_version = 1\n")
      Loader.load(@test_cfg)

      assert Migrator.current_version() == 1
    end
  end

  describe "migrate/0" do
    test "stamps schema_version=1 when starting from v0" do
      File.write!(@test_cfg, "[puppy]\nmodel = test\n")
      Loader.load(@test_cfg)
      ensure_writer_started()

      assert Migrator.current_version() == 0

      {:ok, version} = Migrator.migrate()
      assert version == 1

      Loader.load(@test_cfg)
      assert Migrator.current_version() == 1
    end

    test "is idempotent when already at latest" do
      File.write!(@test_cfg, "[puppy]\nschema_version = 1\n")
      Loader.load(@test_cfg)
      ensure_writer_started()

      {:ok, version} = Migrator.migrate()
      assert version == 1
    end
  end

  describe "rename_key/4" do
    test "renames an existing key" do
      config = %{"puppy" => %{"old_name" => "value", "other" => "keep"}}

      result = Migrator.rename_key(config, "puppy", "old_name", "new_name")

      assert result["puppy"]["new_name"] == "value"
      assert result["puppy"]["other"] == "keep"
      refute Map.has_key?(result["puppy"], "old_name")
    end

    test "does nothing when old key doesn't exist" do
      config = %{"puppy" => %{"other" => "keep"}}

      result = Migrator.rename_key(config, "puppy", "missing", "new_name")

      assert result == config
    end

    test "preserves existing new key value" do
      config = %{"puppy" => %{"old" => "old_val", "new" => "existing"}}

      result = Migrator.rename_key(config, "puppy", "old", "new")

      assert result["puppy"]["new"] == "existing"
      refute Map.has_key?(result["puppy"], "old")
    end
  end

  describe "ensure_key/4" do
    test "sets default when key is missing" do
      config = %{"puppy" => %{"existing" => "val"}}

      result = Migrator.ensure_key(config, "puppy", "missing_key", "default")

      assert result["puppy"]["missing_key"] == "default"
      assert result["puppy"]["existing"] == "val"
    end

    test "does not overwrite existing key" do
      config = %{"puppy" => %{"key" => "original"}}

      result = Migrator.ensure_key(config, "puppy", "key", "new_default")

      assert result["puppy"]["key"] == "original"
    end
  end

  describe "latest_version/0" do
    test "returns a positive integer" do
      assert Migrator.latest_version() >= 1
    end
  end

  defp ensure_writer_started do
    case GenServer.whereis(Writer) do
      nil ->
        {:ok, _} = Writer.start_link()
        :ok

      _pid ->
        :ok
    end
  end
end
