defmodule CodePuppyControl.Tools.CpFileOps.PermissionCheckTest do
  @moduledoc """
  Tests for CpFileOps permission_check/2 (hard gate layer).

  Validates that each tool's permission_check correctly delegates to
  `CpFileOps.validate_path_for_permission/2` and enforces sensitive-path
  deny rules regardless of policy overrides.

  Refs: code_puppy-mmk.1
  """

  use ExUnit.Case

  alias CodePuppyControl.Tools.CpFileOps.{CpListFiles, CpReadFile, CpGrep}

  @test_dir Path.join(
              System.tmp_dir!(),
              "cp_file_ops_perm_#{:erlang.unique_integer([:positive])}"
            )

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    File.write!(Path.join(@test_dir, "hello.txt"), "Hello World\nLine 2\nLine 3")

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    %{test_dir: @test_dir}
  end

  # ============================================================================
  # CpListFiles — permission_check/2
  # ============================================================================

  describe "CpListFiles.permission_check/2" do
    test "allows safe directory path" do
      assert CpListFiles.permission_check(%{"directory" => @test_dir}, %{}) == :ok
    end

    test "allows current directory (default)" do
      assert CpListFiles.permission_check(%{}, %{}) == :ok
    end

    test "denies sensitive directory (.ssh)" do
      ssh_path = Path.join(System.user_home!(), ".ssh")
      assert {:deny, reason} = CpListFiles.permission_check(%{"directory" => ssh_path}, %{})
      assert reason =~ "sensitive path blocked"
    end

    test "denies /etc directory" do
      assert {:deny, reason} = CpListFiles.permission_check(%{"directory" => "/etc"}, %{})
      assert reason =~ "sensitive path blocked"
    end

    test "denies empty string path" do
      assert {:deny, reason} = CpListFiles.permission_check(%{"directory" => ""}, %{})
      assert reason =~ "empty" or reason =~ "cannot be empty"
    end

    test "denies path with null byte" do
      assert {:deny, reason} = CpListFiles.permission_check(%{"directory" => "/foo\x00bar"}, %{})
      assert reason =~ "null byte"
    end

    test "denies case-variant sensitive directory" do
      assert {:deny, _} = CpListFiles.permission_check(%{"directory" => "/ETC"}, %{})
    end
  end

  # ============================================================================
  # CpReadFile — permission_check/2
  # ============================================================================

  describe "CpReadFile.permission_check/2" do
    test "allows safe file path" do
      file_path = Path.join(@test_dir, "hello.txt")
      assert CpReadFile.permission_check(%{"file_path" => file_path}, %{}) == :ok
    end

    test "denies sensitive file path (.ssh/id_rsa)" do
      ssh_key = Path.join(System.user_home!(), ".ssh/id_rsa")
      assert {:deny, reason} = CpReadFile.permission_check(%{"file_path" => ssh_key}, %{})
      assert reason =~ "sensitive path blocked"
    end

    test "denies /etc/shadow" do
      assert {:deny, reason} = CpReadFile.permission_check(%{"file_path" => "/etc/shadow"}, %{})
      assert reason =~ "sensitive path blocked"
    end

    test "denies empty file_path" do
      assert {:deny, reason} = CpReadFile.permission_check(%{"file_path" => ""}, %{})
      assert reason =~ "empty" or reason =~ "cannot be empty"
    end

    test "denies file_path with null byte" do
      assert {:deny, reason} = CpReadFile.permission_check(%{"file_path" => "/foo\x00bar"}, %{})
      assert reason =~ "null byte"
    end

    test "denies private key extension" do
      assert {:deny, _} = CpReadFile.permission_check(%{"file_path" => "/tmp/secret.pem"}, %{})
      assert {:deny, _} = CpReadFile.permission_check(%{"file_path" => "/tmp/cert.key"}, %{})
    end
  end

  # ============================================================================
  # CpGrep — permission_check/2
  # ============================================================================

  describe "CpGrep.permission_check/2" do
    test "allows safe directory path" do
      assert CpGrep.permission_check(%{"directory" => @test_dir, "search_string" => "def"}, %{}) ==
               :ok
    end

    test "allows current directory (default)" do
      assert CpGrep.permission_check(%{"search_string" => "TODO"}, %{}) == :ok
    end

    test "denies sensitive directory (.aws)" do
      aws_path = Path.join(System.user_home!(), ".aws")
      assert {:deny, reason} = CpGrep.permission_check(%{"directory" => aws_path}, %{})
      assert reason =~ "sensitive path blocked"
    end

    test "denies /var/log directory" do
      assert {:deny, reason} = CpGrep.permission_check(%{"directory" => "/var/log"}, %{})
      assert reason =~ "sensitive path blocked"
    end

    test "denies empty directory path" do
      assert {:deny, reason} = CpGrep.permission_check(%{"directory" => ""}, %{})
      assert reason =~ "empty" or reason =~ "cannot be empty"
    end
  end
end
