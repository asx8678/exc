defmodule CodePuppyControl.Pack.TLSTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.TLS

  # ── generate_ssl_dist_config/1 ──────────────────────────────────────────

  describe "generate_ssl_dist_config/1" do
    test "produces valid Erlang term format with server+client blocks" do
      config =
        TLS.generate_ssl_dist_config(
          certfile: "/certs/cert.pem",
          keyfile: "/certs/key.pem",
          cacertfile: "/certs/ca.pem"
        )

      assert config =~ "[{server,"
      assert config =~ "{client,"
      assert String.ends_with?(String.trim(config), "].")
    end

    test "includes all provided cert paths" do
      config =
        TLS.generate_ssl_dist_config(
          certfile: "/my/cert.pem",
          keyfile: "/my/key.pem",
          cacertfile: "/my/ca.pem"
        )

      assert config =~ "/my/cert.pem"
      assert config =~ "/my/key.pem"
      assert config =~ "/my/ca.pem"
    end

    test "defaults verify to verify_peer" do
      config =
        TLS.generate_ssl_dist_config(
          certfile: "/c.pem",
          keyfile: "/k.pem",
          cacertfile: "/ca.pem"
        )

      # The verify value should appear in both server and client blocks
      assert config =~ "verify_peer"
    end

    test "respects custom verify option" do
      config =
        TLS.generate_ssl_dist_config(
          certfile: "/c.pem",
          keyfile: "/k.pem",
          cacertfile: "/ca.pem",
          verify: :verify_none
        )

      assert config =~ "verify_none"
      refute config =~ "verify_peer"
    end

    test "respects custom depth option" do
      config =
        TLS.generate_ssl_dist_config(
          certfile: "/c.pem",
          keyfile: "/k.pem",
          cacertfile: "/ca.pem",
          depth: 5
        )

      assert config =~ "{depth, 5}"
    end

    test "raises on missing required certfile" do
      assert_raise KeyError, fn ->
        TLS.generate_ssl_dist_config(keyfile: "/k.pem", cacertfile: "/ca.pem")
      end
    end

    test "raises on missing required keyfile" do
      assert_raise KeyError, fn ->
        TLS.generate_ssl_dist_config(certfile: "/c.pem", cacertfile: "/ca.pem")
      end
    end

    test "raises on missing required cacertfile" do
      assert_raise KeyError, fn ->
        TLS.generate_ssl_dist_config(certfile: "/c.pem", keyfile: "/k.pem")
      end
    end
  end

  # ── vm_args/1 ──────────────────────────────────────────────────────────

  describe "vm_args/1" do
    test "returns correct flag list with -proto_dist inet_tls" do
      tmp_dir = System.tmp_dir!()
      config_path = Path.join(tmp_dir, "test_ssl_dist_#{:erlang.unique_integer()}.conf")

      args =
        TLS.vm_args(
          certfile: "/c.pem",
          keyfile: "/k.pem",
          cacertfile: "/ca.pem",
          config_path: config_path
        )

      assert args == ["-proto_dist", "inet_tls", "-ssl_dist_optfile", config_path]

      # Clean up
      File.rm(config_path)
    end

    test "writes the ssl_dist.conf file" do
      tmp_dir = System.tmp_dir!()
      config_path = Path.join(tmp_dir, "test_ssl_dist_#{:erlang.unique_integer()}.conf")

      TLS.vm_args(
        certfile: "/c.pem",
        keyfile: "/k.pem",
        cacertfile: "/ca.pem",
        config_path: config_path
      )

      assert File.exists?(config_path)
      content = File.read!(config_path)
      assert content =~ "/c.pem"

      # Clean up
      File.rm(config_path)
    end
  end

  # ── validate_config/1 ──────────────────────────────────────────────────

  describe "validate_config/1" do
    test "returns error when certfile missing" do
      result =
        TLS.validate_config(
          certfile: "/nonexistent/cert.pem",
          keyfile: "/nonexistent/key.pem",
          cacertfile: "/nonexistent/ca.pem"
        )

      assert {:error, reasons} = result
      assert Enum.any?(reasons, &String.contains?(&1, "certfile"))
    end

    test "returns error when keyfile missing" do
      result =
        TLS.validate_config(
          certfile: "/nonexistent/cert.pem",
          keyfile: "/nonexistent/key.pem",
          cacertfile: "/nonexistent/ca.pem"
        )

      assert {:error, reasons} = result
      assert Enum.any?(reasons, &String.contains?(&1, "keyfile"))
    end

    test "returns error when cacertfile missing" do
      result =
        TLS.validate_config(
          certfile: "/nonexistent/cert.pem",
          keyfile: "/nonexistent/key.pem",
          cacertfile: "/nonexistent/ca.pem"
        )

      assert {:error, reasons} = result
      assert Enum.any?(reasons, &String.contains?(&1, "cacertfile"))
    end

    test "returns {:ok, _} when all files exist" do
      # Create temp files
      tmp_dir = System.tmp_dir!()
      certfile = Path.join(tmp_dir, "test_cert_#{:erlang.unique_integer()}.pem")
      keyfile = Path.join(tmp_dir, "test_key_#{:erlang.unique_integer()}.pem")
      cacertfile = Path.join(tmp_dir, "test_ca_#{:erlang.unique_integer()}.pem")

      File.write!(certfile, "dummy cert")
      File.write!(keyfile, "dummy key")
      File.write!(cacertfile, "dummy ca")

      result =
        TLS.validate_config(
          certfile: certfile,
          keyfile: keyfile,
          cacertfile: cacertfile
        )

      assert {:ok, _info} = result

      # Clean up
      File.rm(certfile)
      File.rm(keyfile)
      File.rm(cacertfile)
    end

    test "returns multiple errors when all files missing" do
      result =
        TLS.validate_config(
          certfile: "/no/cert.pem",
          keyfile: "/no/key.pem",
          cacertfile: "/no/ca.pem"
        )

      assert {:error, reasons} = result
      assert length(reasons) == 3
    end
  end

  # ── enabled?/0 ──────────────────────────────────────────────────────────

  describe "enabled?/0" do
    test "returns false by default" do
      # Default config has no TLS enabled
      refute TLS.enabled?()
    end

    test "returns true when TLS is enabled in config" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      try do
        Application.put_env(
          :code_puppy_control,
          :distributed_packs,
          %{tls: %{enabled: true, certfile: "/c.pem", keyfile: "/k.pem", cacertfile: "/ca.pem"}}
        )

        assert TLS.enabled?()
      after
        if original do
          Application.put_env(:code_puppy_control, :distributed_packs, original)
        else
          Application.delete_env(:code_puppy_control, :distributed_packs)
        end
      end
    end
  end

  # ── load_config/0 ──────────────────────────────────────────────────────

  describe "load_config/0" do
    test "returns nil when TLS not configured" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      try do
        Application.delete_env(:code_puppy_control, :distributed_packs)
        assert TLS.load_config() == nil
      after
        if original do
          Application.put_env(:code_puppy_control, :distributed_packs, original)
        else
          Application.delete_env(:code_puppy_control, :distributed_packs)
        end
      end
    end

    test "returns TLS map when configured" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)
      tls_config = %{enabled: true, certfile: "/c.pem", keyfile: "/k.pem", cacertfile: "/ca.pem"}

      try do
        Application.put_env(
          :code_puppy_control,
          :distributed_packs,
          %{tls: tls_config}
        )

        result = TLS.load_config()
        assert result == tls_config
      after
        if original do
          Application.put_env(:code_puppy_control, :distributed_packs, original)
        else
          Application.delete_env(:code_puppy_control, :distributed_packs)
        end
      end
    end

    test "handles keyword list TLS config" do
      original = Application.get_env(:code_puppy_control, :distributed_packs)

      try do
        Application.put_env(
          :code_puppy_control,
          :distributed_packs,
          tls: [enabled: true, certfile: "/c.pem"]
        )

        result = TLS.load_config()
        assert is_map(result)
        assert result[:enabled] == true
      after
        if original do
          Application.put_env(:code_puppy_control, :distributed_packs, original)
        else
          Application.delete_env(:code_puppy_control, :distributed_packs)
        end
      end
    end
  end

  # ── write_ssl_dist_config!/2 ──────────────────────────────────────────

  describe "write_ssl_dist_config!/2" do
    test "writes config file and creates parent directories" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer()
      path = Path.join(tmp_dir, "tls_test_#{unique}/sub/ssl_dist.conf")

      :ok =
        TLS.write_ssl_dist_config!(
          path,
          certfile: "/c.pem",
          keyfile: "/k.pem",
          cacertfile: "/ca.pem"
        )

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "/c.pem"
      assert content =~ "/k.pem"
      assert content =~ "/ca.pem"

      # Clean up
      File.rm_rf!(Path.join(tmp_dir, "tls_test_#{unique}"))
    end
  end
end
