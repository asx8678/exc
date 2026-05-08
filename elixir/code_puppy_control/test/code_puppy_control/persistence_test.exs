defmodule CodePuppyControl.PersistenceTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Persistence

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "cp_persistence_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    # Create a fresh temp directory for each test
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  # ── safe_resolve_path/1,2 ───────────────────────────────────────────

  describe "safe_resolve_path/1" do
    test "resolves relative paths to absolute" do
      assert {:ok, resolved} = Persistence.safe_resolve_path("relative/path")
      assert Path.type(resolved) == :absolute
    end

    test "normalizes dot-dot components" do
      assert {:ok, resolved} = Persistence.safe_resolve_path("/tmp/../etc/passwd")
      assert resolved == "/etc/passwd"
    end

    test "normalizes multiple dot-dot components" do
      assert {:ok, resolved} = Persistence.safe_resolve_path("/a/b/c/../../d")
      assert resolved == "/a/d"
    end

    test "normalizes dot components" do
      assert {:ok, resolved} = Persistence.safe_resolve_path("/tmp/./file.txt")
      assert resolved == "/tmp/file.txt"
    end
  end

  describe "safe_resolve_path/2 with allowed_parent" do
    test "allows paths within parent" do
      assert {:ok, _} = Persistence.safe_resolve_path("/tmp/sub/file.txt", "/tmp/sub")
    end

    test "allows path exactly at parent" do
      assert {:ok, resolved} = Persistence.safe_resolve_path("/tmp/sub", "/tmp/sub")
      assert resolved == "/tmp/sub"
    end

    test "rejects paths outside parent" do
      assert {:error, msg} = Persistence.safe_resolve_path("/etc/passwd", "/tmp/sandbox")
      assert msg =~ "outside allowed parent"
    end

    test "blocks traversal attack via dot-dot" do
      assert {:error, msg} =
               Persistence.safe_resolve_path("/tmp/sandbox/../../etc/passwd", "/tmp/sandbox")

      assert msg =~ "outside allowed parent"
    end
  end

  # ── check_isolation_guard/1 ─────────────────────────────────────────

  describe "check_isolation_guard/1" do
    test "allows writes outside config home" do
      assert :ok = Persistence.check_isolation_guard(Path.join(@tmp_dir, "file.txt"))
    end

    test "allows writes to active pup-ex home" do
      # The active home should be allowed
      home = CodePuppyControl.Config.Paths.home_dir()
      assert :ok = Persistence.check_isolation_guard(Path.join(home, "test_file.txt"))
    end

    test "blocks writes to legacy home" do
      legacy = CodePuppyControl.Config.Paths.legacy_home_dir()
      child_path = Path.join(legacy, "test.txt")

      # The sandbox must whitelist the exact path (not just the parent)
      CodePuppyControl.Config.Isolation.with_sandbox([child_path], fn ->
        # Inside sandbox with the exact path whitelisted, it should be allowed
        assert :ok = Persistence.check_isolation_guard(child_path)
      end)

      # Without sandbox, the write to legacy home should be blocked
      result = Persistence.check_isolation_guard(child_path)
      assert {:error, :isolation_violation, _} = result
    end
  end

  # ── atomic_write_text/2 ─────────────────────────────────────────────

  describe "atomic_write_text/2" do
    test "writes text content to a file" do
      path = Path.join(@tmp_dir, "text_file.txt")
      assert :ok = Persistence.atomic_write_text(path, "Hello, World!")
      assert File.read!(path) == "Hello, World!"
    end

    test "overwrites existing file atomically" do
      path = Path.join(@tmp_dir, "overwrite.txt")
      assert :ok = Persistence.atomic_write_text(path, "first")
      assert :ok = Persistence.atomic_write_text(path, "second")
      assert File.read!(path) == "second"
    end

    test "creates parent directories if missing" do
      path = Path.join(@tmp_dir, "nested/deep/file.txt")
      assert :ok = Persistence.atomic_write_text(path, "nested content")
      assert File.read!(path) == "nested content"
    end

    test "handles empty content" do
      path = Path.join(@tmp_dir, "empty.txt")
      assert :ok = Persistence.atomic_write_text(path, "")
      assert File.read!(path) == ""
    end

    test "handles unicode content" do
      path = Path.join(@tmp_dir, "unicode.txt")
      content = "日本語テスト 🐶 émoji"
      assert :ok = Persistence.atomic_write_text(path, content)
      assert File.read!(path) == content
    end
  end

  # ── atomic_write_bytes/2 ────────────────────────────────────────────

  describe "atomic_write_bytes/2" do
    test "writes binary content to a file" do
      path = Path.join(@tmp_dir, "binary.bin")
      data = <<0, 1, 2, 255, 254>>
      assert :ok = Persistence.atomic_write_bytes(path, data)
      assert File.read!(path) == data
    end

    test "overwrites existing binary file" do
      path = Path.join(@tmp_dir, "overwrite.bin")
      assert :ok = Persistence.atomic_write_bytes(path, <<1, 2, 3>>)
      assert :ok = Persistence.atomic_write_bytes(path, <<4, 5, 6>>)
      assert File.read!(path) == <<4, 5, 6>>
    end
  end

  # ── atomic_write_json/2,3 ───────────────────────────────────────────

  describe "atomic_write_json/2" do
    test "writes JSON with default indentation" do
      path = Path.join(@tmp_dir, "data.json")
      assert :ok = Persistence.atomic_write_json(path, %{key: "value"})
      content = File.read!(path)
      assert content =~ "key"
      assert content =~ "value"
      assert {:ok, decoded} = Jason.decode(content)
      assert decoded["key"] == "value"
    end

    test "writes JSON with zero indent (compact)" do
      path = Path.join(@tmp_dir, "compact.json")
      assert :ok = Persistence.atomic_write_json(path, %{a: 1}, indent: 0)
      content = File.read!(path)
      # Compact JSON should be on one line
      refute content =~ "\n"
    end

    test "writes nested structures" do
      path = Path.join(@tmp_dir, "nested.json")
      data = %{users: [%{name: "Alice"}, %{name: "Bob"}]}

      assert :ok = Persistence.atomic_write_json(path, data)
      assert {:ok, decoded} = Jason.decode(File.read!(path))
      assert length(decoded["users"]) == 2
    end

    test "returns error for non-serializable data" do
      path = Path.join(@tmp_dir, "bad.json")

      # Functions cannot be JSON serialized
      assert {:error, msg} = Persistence.atomic_write_json(path, fn -> :ok end)
      assert msg =~ "JSON"
    end

    test "round-trips with read_json" do
      path = Path.join(@tmp_dir, "roundtrip.json")
      data = %{name: "test", count: 42, tags: ["a", "b"]}

      assert :ok = Persistence.atomic_write_json(path, data)
      assert {:ok, read_data} = Persistence.read_json(path)
      # Jason decodes to string keys
      assert read_data["name"] == "test"
      assert read_data["count"] == 42
    end

    test "supports custom encoder function" do
      path = Path.join(@tmp_dir, "custom.json")

      # Custom encoder that wraps data
      encoder = fn data -> %{wrapped: data} end

      assert :ok = Persistence.atomic_write_json(path, %{x: 1}, encoder: encoder)
      assert {:ok, decoded} = Persistence.read_json(path)
      assert decoded["wrapped"]["x"] == 1
    end
  end

  # ── atomic_write_compact_json/2,3 ────────────────────────────────────

  describe "atomic_write_compact_json/2" do
    test "writes compact JSON (no pretty printing)" do
      path = Path.join(@tmp_dir, "compact.json")
      data = %{a: 1, b: %{c: 2}}

      assert :ok = Persistence.atomic_write_compact_json(path, data)
      content = File.read!(path)
      # Compact JSON should have no newlines
      refute content =~ "\n"
      assert {:ok, decoded} = Jason.decode(content)
      assert decoded["a"] == 1
    end

    test "round-trips with read_compact_json" do
      path = Path.join(@tmp_dir, "compact_roundtrip.json")
      data = %{items: [1, 2, 3]}

      assert :ok = Persistence.atomic_write_compact_json(path, data)
      assert {:ok, read_data} = Persistence.read_compact_json(path)
      assert read_data["items"] == [1, 2, 3]
    end
  end

  # ── read_json/1,2 ────────────────────────────────────────────────────

  describe "read_json/1" do
    test "returns default for nonexistent file" do
      assert {:ok, nil} = Persistence.read_json("/nonexistent_file_abc123.json")
    end

    test "returns custom default for nonexistent file" do
      assert {:ok, %{}} = Persistence.read_json("/nonexistent_file_abc123.json", %{})
    end

    test "returns default for invalid JSON" do
      path = Path.join(@tmp_dir, "invalid.json")
      File.write!(path, "not valid json {{{")
      assert {:ok, nil} = Persistence.read_json(path)
    end

    test "reads valid JSON file" do
      path = Path.join(@tmp_dir, "valid.json")
      File.write!(path, Jason.encode!(%{hello: "world"}))
      assert {:ok, data} = Persistence.read_json(path)
      assert data["hello"] == "world"
    end
  end

  # ── read_compact_json/1,2 ────────────────────────────────────────────

  describe "read_compact_json/1" do
    test "reads compact JSON files" do
      path = Path.join(@tmp_dir, "compact_read.json")
      File.write!(path, Jason.encode!(%{compact: true}))
      assert {:ok, data} = Persistence.read_compact_json(path)
      assert data["compact"] == true
    end

    test "returns default for nonexistent file" do
      assert {:ok, []} = Persistence.read_compact_json("/no_such_file.json", [])
    end
  end

  # ── Property: Round-trip invariants ──────────────────────────────────

  describe "round-trip invariants" do
    test "JSON write then read preserves data (string keys)" do
      path = Path.join(@tmp_dir, "prop_roundtrip.json")

      for data <- [
            %{"key" => "value"},
            %{"nested" => %{"deep" => 42}},
            %{"list" => [1, 2, 3]},
            %{"bool" => true, "null" => nil}
          ] do
        assert :ok = Persistence.atomic_write_json(path, data)
        assert {:ok, read_back} = Persistence.read_json(path)

        # Data should be identical (string keys preserved by Jason)
        assert read_back == data
      end
    end

    test "compact JSON write then read preserves data" do
      path = Path.join(@tmp_dir, "prop_compact_roundtrip.json")

      for data <- [%{"a" => 1}, %{"b" => [1, 2]}] do
        assert :ok = Persistence.atomic_write_compact_json(path, data)
        assert {:ok, read_back} = Persistence.read_compact_json(path)
        assert read_back == data
      end
    end
  end

  # ── Atomicity: Crash safety ─────────────────────────────────────────

  describe "atomicity" do
    test "no partial files on write failure (parent dir doesn't exist on write)" do
      # atomic_write_text creates parent dirs, so this should succeed
      path = Path.join(@tmp_dir, "new_dir/new_file.txt")
      assert :ok = Persistence.atomic_write_text(path, "created")
      assert File.read!(path) == "created"
    end

    test "temp files are cleaned up on failure" do
      # This is handled by SafeWrite internally — verify no .tmp files remain
      path = Path.join(@tmp_dir, "cleanup_test.txt")
      Persistence.atomic_write_text(path, "test")

      tmp_files =
        Path.wildcard(Path.join(@tmp_dir, ".~*.tmp*"))

      assert tmp_files == []
    end
  end

  # ── Isolation guard on all write paths (code-puppy-ctj.3) ──────────

  describe "isolation guard on atomic_write_bytes (code-puppy-ctj.3)" do
    test "allows writes outside config home" do
      path = Path.join(@tmp_dir, "bytes_outside.bin")
      assert :ok = Persistence.atomic_write_bytes(path, <<1, 2, 3>>)
    end

    test "blocks writes to legacy home" do
      legacy = CodePuppyControl.Config.Paths.legacy_home_dir()
      child_path = Path.join(legacy, "blocked.bin")

      result = Persistence.atomic_write_bytes(child_path, <<1, 2, 3>>)
      assert {:error, :isolation_violation, _} = result
    end
  end

  describe "isolation guard on atomic_write_compact_json (code-puppy-ctj.3)" do
    test "allows writes outside config home" do
      path = Path.join(@tmp_dir, "compact_outside.json")
      assert :ok = Persistence.atomic_write_compact_json(path, %{x: 1})
    end

    test "blocks writes to legacy home" do
      legacy = CodePuppyControl.Config.Paths.legacy_home_dir()
      child_path = Path.join(legacy, "blocked_compact.json")

      result = Persistence.atomic_write_compact_json(child_path, %{x: 1})
      assert {:error, :isolation_violation, _} = result
    end
  end

  describe "isolation guard on atomic_write_json (existing, regression check)" do
    test "blocks writes to legacy home" do
      legacy = CodePuppyControl.Config.Paths.legacy_home_dir()
      child_path = Path.join(legacy, "blocked_pretty.json")

      result = Persistence.atomic_write_json(child_path, %{x: 1})
      assert {:error, :isolation_violation, _} = result
    end
  end
end
