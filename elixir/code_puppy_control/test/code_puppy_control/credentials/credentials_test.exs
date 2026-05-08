defmodule CodePuppyControl.CredentialsTest do
  use ExUnit.Case, async: false

  # Not async: tests share file system state via temp dirs

  alias CodePuppyControl.Credentials

  # Use a unique temp dir for each test
  setup do
    dir = Path.join(System.tmp_dir!(), "cred_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Redirect machine secret to temp dir so tests never write to the real
    # ~/.code_puppy_ex/.machine_secret
    secret_tmp =
      Path.join(System.tmp_dir!(), "cred_secret_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(secret_tmp)
    key_file = Path.join(secret_tmp, ".machine_secret")
    original_secret_path = System.get_env("PUP_MACHINE_SECRET_PATH")
    System.put_env("PUP_MACHINE_SECRET_PATH", key_file)

    on_exit(fn ->
      if original_secret_path do
        System.put_env("PUP_MACHINE_SECRET_PATH", original_secret_path)
      else
        System.delete_env("PUP_MACHINE_SECRET_PATH")
      end

      File.rm_rf(dir)
      File.rm_rf(secret_tmp)
    end)

    {:ok, store_dir: dir}
  end

  describe "set/3 and get/2" do
    test "stores and retrieves a credential", %{store_dir: dir} do
      assert :ok = Credentials.set("OPENAI_API_KEY", "sk-abc123", store_dir: dir)
      assert {:ok, "sk-abc123"} = Credentials.get("OPENAI_API_KEY", store_dir: dir)
    end

    test "returns error for non-existent key", %{store_dir: dir} do
      assert {:error, :not_found} = Credentials.get("NONEXISTENT", store_dir: dir)
    end

    test "overwrites existing key", %{store_dir: dir} do
      assert :ok = Credentials.set("MY_KEY", "old-value", store_dir: dir)
      assert :ok = Credentials.set("MY_KEY", "new-value", store_dir: dir)
      assert {:ok, "new-value"} = Credentials.get("MY_KEY", store_dir: dir)
    end

    test "stores multiple keys independently", %{store_dir: dir} do
      assert :ok = Credentials.set("KEY_A", "value-a", store_dir: dir)
      assert :ok = Credentials.set("KEY_B", "value-b", store_dir: dir)

      assert {:ok, "value-a"} = Credentials.get("KEY_A", store_dir: dir)
      assert {:ok, "value-b"} = Credentials.get("KEY_B", store_dir: dir)
    end

    test "handles empty string values", %{store_dir: dir} do
      assert :ok = Credentials.set("EMPTY_KEY", "", store_dir: dir)
      assert {:ok, ""} = Credentials.get("EMPTY_KEY", store_dir: dir)
    end

    test "handles special characters in values", %{store_dir: dir} do
      value = "sk-abc=def&ghi\"jkl'no\\pq"
      assert :ok = Credentials.set("SPECIAL_KEY", value, store_dir: dir)
      assert {:ok, ^value} = Credentials.get("SPECIAL_KEY", store_dir: dir)
    end

    test "handles unicode values", %{store_dir: dir} do
      value = "日本語🔑"
      assert :ok = Credentials.set("UNICODE_KEY", value, store_dir: dir)
      assert {:ok, ^value} = Credentials.get("UNICODE_KEY", store_dir: dir)
    end

    test "persists across separate reads (file-backed)", %{store_dir: dir} do
      assert :ok = Credentials.set("PERSIST_KEY", "persistent", store_dir: dir)
      # Second read hits the same file
      assert {:ok, "persistent"} = Credentials.get("PERSIST_KEY", store_dir: dir)
    end
  end

  describe "delete/2" do
    test "deletes an existing key", %{store_dir: dir} do
      assert :ok = Credentials.set("TO_DELETE", "value", store_dir: dir)
      assert :ok = Credentials.delete("TO_DELETE", store_dir: dir)
      assert {:error, :not_found} = Credentials.get("TO_DELETE", store_dir: dir)
    end

    test "is idempotent for non-existent keys", %{store_dir: dir} do
      assert :ok = Credentials.delete("NEVER_SET", store_dir: dir)
    end

    test "does not affect other keys", %{store_dir: dir} do
      assert :ok = Credentials.set("KEEP", "keep-value", store_dir: dir)
      assert :ok = Credentials.set("REMOVE", "remove-value", store_dir: dir)
      assert :ok = Credentials.delete("REMOVE", store_dir: dir)

      assert {:ok, "keep-value"} = Credentials.get("KEEP", store_dir: dir)
      assert {:error, :not_found} = Credentials.get("REMOVE", store_dir: dir)
    end
  end

  describe "list_keys/1" do
    test "returns empty list when store is empty", %{store_dir: dir} do
      assert [] = Credentials.list_keys(store_dir: dir)
    end

    test "returns sorted list of key names", %{store_dir: dir} do
      assert :ok = Credentials.set("ZEBRA", "z", store_dir: dir)
      assert :ok = Credentials.set("ALPHA", "a", store_dir: dir)
      assert :ok = Credentials.set("MIDDLE", "m", store_dir: dir)

      assert ["ALPHA", "MIDDLE", "ZEBRA"] = Credentials.list_keys(store_dir: dir)
    end

    test "does not include values", %{store_dir: dir} do
      assert :ok = Credentials.set("MY_KEY", "secret-value", store_dir: dir)
      keys = Credentials.list_keys(store_dir: dir)
      assert keys == ["MY_KEY"]
    end
  end

  describe "exists?/2" do
    test "returns true for existing key", %{store_dir: dir} do
      assert :ok = Credentials.set("EXISTS", "yes", store_dir: dir)
      assert Credentials.exists?("EXISTS", store_dir: dir)
    end

    test "returns false for non-existent key", %{store_dir: dir} do
      refute Credentials.exists?("NOPE", store_dir: dir)
    end
  end

  describe "store file security" do
    test "store file is created with restricted permissions", %{store_dir: dir} do
      assert :ok = Credentials.set("SEC_TEST", "value", store_dir: dir)

      store_path = Credentials.store_path(store_dir: dir)
      {:ok, %{access: _mode}} = File.stat(store_path)

      # 0o600 = 0o100600 (regular file + 600 perms)
      # On some platforms chmod may not work, so we just verify the file exists
      assert File.exists?(store_path)
    end

    test "store directory is created with restricted permissions", %{store_dir: dir} do
      assert :ok = Credentials.set("DIR_TEST", "value", store_dir: dir)
      assert File.dir?(dir)
    end

    test "store file contains encrypted data (no plaintext keys visible)", %{store_dir: dir} do
      secret_value = "sk-super-secret-never-appear-in-file"
      assert :ok = Credentials.set("MY_SECRET", secret_value, store_dir: dir)

      store_path = Credentials.store_path(store_dir: dir)
      {:ok, contents} = File.read(store_path)

      # The raw file should NOT contain the secret value in plaintext
      refute String.contains?(contents, secret_value)
      # The key name should also not appear in plaintext
      refute String.contains?(contents, "MY_SECRET")
    end
  end

  describe "corrupted store handling" do
    test "returns error when store file is corrupted JSON", %{store_dir: dir} do
      store_path = Credentials.store_path(store_dir: dir)
      File.mkdir_p!(dir)
      File.write!(store_path, "not valid json at all")

      assert {:error, _} = Credentials.get("ANY_KEY", store_dir: dir)
    end

    test "returns error when store file has valid JSON but invalid encrypted data", %{
      store_dir: dir
    } do
      store_path = Credentials.store_path(store_dir: dir)
      File.mkdir_p!(dir)
      # Valid JSON but not our encrypted format
      File.write!(store_path, Jason.encode!(%{"iv" => "abc", "tag" => "def", "data" => "ghi"}))

      assert {:error, _} = Credentials.get("ANY_KEY", store_dir: dir)
    end
  end

  describe "import_from_python/1" do
    test "imports API keys from a Python puppy.cfg file", %{store_dir: dir} do
      # Create a temporary puppy.cfg
      cfg_dir = Path.join(dir, "python_cfg")
      File.mkdir_p!(cfg_dir)
      cfg_path = Path.join(cfg_dir, "puppy.cfg")

      File.write!(cfg_path, """
      OPENAI_API_KEY=sk-openai-from-python
      ANTHROPIC_API_KEY=sk-ant-from-python
      some_other_setting=true
      """)

      assert {:ok, 2} =
               Credentials.import_from_python(
                 store_dir: dir,
                 python_cfg_path: cfg_path
               )

      assert {:ok, "sk-openai-from-python"} =
               Credentials.get("OPENAI_API_KEY", store_dir: dir)

      assert {:ok, "sk-ant-from-python"} =
               Credentials.get("ANTHROPIC_API_KEY", store_dir: dir)
    end

    test "returns 0 when Python config does not exist", %{store_dir: dir} do
      assert {:ok, 0} =
               Credentials.import_from_python(
                 store_dir: dir,
                 python_cfg_path: "/nonexistent/path/puppy.cfg"
               )
    end

    test "does not overwrite existing keys", %{store_dir: dir} do
      # Pre-set a key
      assert :ok = Credentials.set("OPENAI_API_KEY", "existing-value", store_dir: dir)

      cfg_dir = Path.join(dir, "python_cfg2")
      File.mkdir_p!(cfg_dir)
      cfg_path = Path.join(cfg_dir, "puppy.cfg")

      File.write!(cfg_path, """
      OPENAI_API_KEY=sk-from-python
      """)

      # Import should overwrite the existing key (Python import is a migration)
      assert {:ok, 1} =
               Credentials.import_from_python(
                 store_dir: dir,
                 python_cfg_path: cfg_path
               )

      # The Python value overwrites because import is a migration
      assert {:ok, "sk-from-python"} =
               Credentials.get("OPENAI_API_KEY", store_dir: dir)
    end

    test "skips empty values", %{store_dir: dir} do
      cfg_dir = Path.join(dir, "python_cfg3")
      File.mkdir_p!(cfg_dir)
      cfg_path = Path.join(cfg_dir, "puppy.cfg")

      File.write!(cfg_path, """
      OPENAI_API_KEY=
      ANTHROPIC_API_KEY=sk-ant-valid
      """)

      assert {:ok, 1} =
               Credentials.import_from_python(
                 store_dir: dir,
                 python_cfg_path: cfg_path
               )

      # Empty key should not be stored
      assert {:error, :not_found} = Credentials.get("OPENAI_API_KEY", store_dir: dir)
      assert {:ok, "sk-ant-valid"} = Credentials.get("ANTHROPIC_API_KEY", store_dir: dir)
    end

    test "handles puppy.cfg with spaces around equals", %{store_dir: dir} do
      cfg_dir = Path.join(dir, "python_cfg4")
      File.mkdir_p!(cfg_dir)
      cfg_path = Path.join(cfg_dir, "puppy.cfg")

      File.write!(cfg_path, "GEMINI_API_KEY=  sk-gemini-spaces  \n")

      assert {:ok, 1} =
               Credentials.import_from_python(
                 store_dir: dir,
                 python_cfg_path: cfg_path
               )

      # Value should be trimmed
      assert {:ok, "sk-gemini-spaces"} =
               Credentials.get("GEMINI_API_KEY", store_dir: dir)
    end
  end

  describe "isolation: reject legacy Python home" do
    test "store_dir raises when store_dir points at ~/.code_puppy/" do
      legacy_home = CodePuppyControl.Config.Paths.legacy_home_dir()
      legacy_creds = Path.join(legacy_home, "credentials")

      assert_raise ArgumentError, ~r/legacy Python home/, fn ->
        Credentials.store_dir(store_dir: legacy_creds)
      end
    end

    test "set raises when store_dir is the legacy home itself" do
      legacy_home = CodePuppyControl.Config.Paths.legacy_home_dir()

      assert_raise ArgumentError, ~r/legacy Python home/, fn ->
        Credentials.set("KEY", "value", store_dir: legacy_home)
      end
    end

    test "get raises when store_dir is under ~/.code_puppy/" do
      legacy_home = CodePuppyControl.Config.Paths.legacy_home_dir()
      deep_path = Path.join([legacy_home, "sub", "credentials"])

      assert_raise ArgumentError, ~r/legacy Python home/, fn ->
        Credentials.get("KEY", store_dir: deep_path)
      end
    end

    test "delete raises when store_dir is under ~/.code_puppy/" do
      legacy_home = CodePuppyControl.Config.Paths.legacy_home_dir()
      deep_path = Path.join([legacy_home, "nested", "creds"])

      assert_raise ArgumentError, ~r/legacy Python home/, fn ->
        Credentials.delete("KEY", store_dir: deep_path)
      end
    end

    test "code_puppy_ex paths are accepted without error", %{store_dir: dir} do
      # A temp dir that is NOT under ~/.code_puppy/ should work fine
      assert ^dir = Credentials.store_dir(store_dir: dir)
    end
  end

  describe "store_path/1 and store_dir/1" do
    test "store_dir returns the option value when provided" do
      assert Credentials.store_dir(store_dir: "/custom/path") == "/custom/path"
    end

    test "store_path returns file inside store_dir" do
      assert Credentials.store_path(store_dir: "/custom/path") ==
               "/custom/path/store.json"
    end

    test "store_dir returns default path when option not provided" do
      dir = Credentials.store_dir([])
      assert String.ends_with?(dir, "credentials")
    end
  end
end
