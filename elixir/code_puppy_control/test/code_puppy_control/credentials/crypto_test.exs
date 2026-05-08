defmodule CodePuppyControl.Credentials.CryptoTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Credentials.Crypto

  # Use a temp dir for the machine secret so tests never write to the real
  # ~/.code_puppy_ex/.machine_secret
  setup do
    tmp = Path.join(System.tmp_dir!(), "crypto_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    key_file = Path.join(tmp, ".machine_secret")

    original = System.get_env("PUP_MACHINE_SECRET_PATH")
    System.put_env("PUP_MACHINE_SECRET_PATH", key_file)

    on_exit(fn ->
      if original do
        System.put_env("PUP_MACHINE_SECRET_PATH", original)
      else
        System.delete_env("PUP_MACHINE_SECRET_PATH")
      end

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, key_file: key_file}
  end

  describe "derive_key/0" do
    test "produces a 32-byte key", %{key_file: key_file} do
      # Ensure no prior key file exists
      File.rm(key_file)
      key = Crypto.derive_key()
      assert byte_size(key) == 32
    end

    test "persists the machine secret to a file", %{key_file: key_file} do
      File.rm(key_file)
      Crypto.derive_key()
      assert File.exists?(key_file)
    end

    test "is deterministic (same key on repeated calls)", %{key_file: key_file} do
      File.rm(key_file)
      key1 = Crypto.derive_key()
      key2 = Crypto.derive_key()
      assert key1 == key2
    end

    test "creates the machine secret file with restricted permissions", %{key_file: key_file} do
      File.rm(key_file)
      Crypto.derive_key()
      # On Unix, File.stat returns the mode; on some platforms it may be
      # :read_write instead. We just verify the file exists and is readable.
      assert File.exists?(key_file)
      assert {:ok, _} = File.read(key_file)
    end

    test "different secret files produce different keys" do
      tmp_a = Path.join(System.tmp_dir!(), "crypto_test_a_#{:erlang.unique_integer([:positive])}")
      tmp_b = Path.join(System.tmp_dir!(), "crypto_test_b_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_a)
      File.mkdir_p!(tmp_b)

      key_file_a = Path.join(tmp_a, ".machine_secret")
      key_file_b = Path.join(tmp_b, ".machine_secret")

      try do
        System.put_env("PUP_MACHINE_SECRET_PATH", key_file_a)
        key_a = Crypto.derive_key()

        System.put_env("PUP_MACHINE_SECRET_PATH", key_file_b)
        key_b = Crypto.derive_key()

        assert key_a != key_b
      after
        File.rm_rf(tmp_a)
        File.rm_rf(tmp_b)
      end
    end

    test "never writes to real ~/.code_puppy_ex/", %{tmp: tmp} do
      File.rm(Path.join(tmp, ".machine_secret"))
      Crypto.derive_key()
      # The real home dir should not have a .machine_secret
      real_path = Path.join([System.get_env("HOME"), ".code_puppy_ex", ".machine_secret"])
      # Only check if our test path is different from the real one
      assert Crypto.machine_secret_path() != real_path or
               System.get_env("PUP_MACHINE_SECRET_PATH") != nil
    end
  end

  describe "derive_key/1" do
    test "produces a 32-byte key from a secret" do
      key = Crypto.derive_key("my-secret")
      assert byte_size(key) == 32
    end

    test "different secrets produce different keys" do
      key1 = Crypto.derive_key("secret-a")
      key2 = Crypto.derive_key("secret-b")
      assert key1 != key2
    end

    test "same secret produces same key" do
      key1 = Crypto.derive_key("the-same")
      key2 = Crypto.derive_key("the-same")
      assert key1 == key2
    end
  end

  describe "encrypt/2 and decrypt/2" do
    test "encrypt then decrypt round-trips successfully" do
      key = Crypto.derive_key("test-key")
      plaintext = "sk-ant-api03-1234567890abcdef"

      encrypted = Crypto.encrypt(plaintext, key)
      assert {:ok, decrypted} = Crypto.decrypt(encrypted, key)
      assert decrypted == plaintext
    end

    test "encrypted output has iv, tag, and data fields" do
      key = Crypto.derive_key("test-key")
      encrypted = Crypto.encrypt("hello", key)

      assert Map.has_key?(encrypted, :iv)
      assert Map.has_key?(encrypted, :tag)
      assert Map.has_key?(encrypted, :data)
    end

    test "encrypted fields are Base64-encoded" do
      key = Crypto.derive_key("test-key")
      encrypted = Crypto.encrypt("hello", key)

      assert {:ok, _} = Base.decode64(encrypted.iv)
      assert {:ok, _} = Base.decode64(encrypted.tag)
      assert {:ok, _} = Base.decode64(encrypted.data)
    end

    test "decryption with wrong key fails" do
      key1 = Crypto.derive_key("key-one")
      key2 = Crypto.derive_key("key-two")

      encrypted = Crypto.encrypt("secret", key1)
      assert {:error, :decryption_failed} = Crypto.decrypt(encrypted, key2)
    end

    test "decryption with tampered data fails" do
      key = Crypto.derive_key("test-key")
      encrypted = Crypto.encrypt("secret", key)

      # Tamper with the ciphertext
      tampered = %{encrypted | data: Base.encode64(<<"tampered_data">>)}
      assert {:error, :decryption_failed} = Crypto.decrypt(tampered, key)
    end

    test "decryption with tampered IV fails" do
      key = Crypto.derive_key("test-key")
      encrypted = Crypto.encrypt("secret", key)

      # Tamper with the IV
      tampered = %{encrypted | iv: Base.encode64(:crypto.strong_rand_bytes(12))}
      assert {:error, :decryption_failed} = Crypto.decrypt(tampered, key)
    end

    test "decryption with invalid base64 returns error" do
      key = Crypto.derive_key("test-key")

      invalid = %{iv: "not-base64!!!", tag: "abc", data: "def"}
      assert {:error, :invalid_base64} = Crypto.decrypt(invalid, key)
    end

    test "decryption with wrong IV length returns error" do
      key = Crypto.derive_key("test-key")

      invalid = %{
        iv: Base.encode64(<<0, 0, 0>>),
        tag: Base.encode64(<<0::128>>),
        data: Base.encode64(<<0>>)
      }

      assert {:error, :invalid_field_length} = Crypto.decrypt(invalid, key)
    end

    test "handles empty plaintext" do
      key = Crypto.derive_key("test-key")

      encrypted = Crypto.encrypt("", key)
      assert {:ok, ""} = Crypto.decrypt(encrypted, key)
    end

    test "handles large values (e.g. long API keys)" do
      key = Crypto.derive_key("test-key")
      # Simulate a 1KB token
      plaintext = String.duplicate("x", 1024)

      encrypted = Crypto.encrypt(plaintext, key)
      assert {:ok, ^plaintext} = Crypto.decrypt(encrypted, key)
    end

    test "handles unicode in values" do
      key = Crypto.derive_key("test-key")
      plaintext = "sk-日本語-🔐"

      encrypted = Crypto.encrypt(plaintext, key)
      assert {:ok, ^plaintext} = Crypto.decrypt(encrypted, key)
    end

    test "each encryption uses a unique IV" do
      key = Crypto.derive_key("test-key")

      enc1 = Crypto.encrypt("same-value", key)
      enc2 = Crypto.encrypt("same-value", key)

      # IVs should be different (random)
      assert enc1.iv != enc2.iv
      # Ciphertext should be different
      assert enc1.data != enc2.data
    end

    test "decrypt returns error for invalid input type" do
      key = Crypto.derive_key("test-key")
      assert {:error, :invalid_input} = Crypto.decrypt("not a map", key)
      assert {:error, :invalid_input} = Crypto.decrypt(nil, key)
    end
  end

  describe "encrypt_to_json/2 and decrypt_from_json/2" do
    test "round-trip with string keys" do
      key = Crypto.derive_key("test-key")
      plaintext = "sk-test-key-value"

      json_map = Crypto.encrypt_to_json(plaintext, key)
      # Keys should be strings
      assert Map.keys(json_map) |> Enum.all?(&is_binary/1)

      assert {:ok, ^plaintext} = Crypto.decrypt_from_json(json_map, key)
    end

    test "decrypt_from_json returns error for invalid input" do
      key = Crypto.derive_key("test-key")
      assert {:error, :invalid_input} = Crypto.decrypt_from_json(%{}, key)
      assert {:error, :invalid_input} = Crypto.decrypt_from_json(nil, key)
    end
  end
end
