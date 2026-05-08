defmodule CodePuppyControl.SessionStorage.FormatTest do
  @moduledoc """
  Tests for CodePuppyControl.SessionStorage.Format.

  Covers format detection, name normalization, path building,
  and Python JSON+HMAC parsing.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.SessionStorage.Format

  describe "current_format/0" do
    test "returns the format identifier" do
      assert Format.current_format() == "code-puppy-ex-v1"
    end
  end

  describe "detect_format/1" do
    test "detects Python JSON+HMAC format" do
      magic = "JSONV\x01\x00\x00"
      hmac = :binary.copy(<<0>>, 32)
      json = Jason.encode!(%{"messages" => []})
      assert Format.detect_format(magic <> hmac <> json) == :python_json_hmac
    end

    test "detects Python plain JSON (pydantic-ai) format" do
      data = Jason.encode!(%{"format" => "pydantic-ai-json-v2", "payload" => []})
      assert Format.detect_format(data) == :python_plain_json
    end

    test "detects Elixir-native JSON format" do
      data = Jason.encode!(%{"format" => "code-puppy-ex-v1", "payload" => %{}})
      assert Format.detect_format(data) == :elixir_json
    end

    test "returns :unknown for random bytes" do
      assert Format.detect_format(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>) == :unknown
    end

    test "returns :unknown for unknown format string" do
      data = Jason.encode!(%{"format" => "future-format-v99"})
      assert Format.detect_format(data) == :unknown
    end
  end

  describe "parse_python_json_hmac/1" do
    test "parses valid JSONV+HMAC data" do
      magic = "JSONV\x01\x00\x00"
      fake_hmac = :binary.copy(<<0>>, 32)
      payload = %{"messages" => [%{"role" => "user"}], "compacted_hashes" => []}
      json = Jason.encode!(payload)

      assert {:ok, decoded} = Format.parse_python_json_hmac(magic <> fake_hmac <> json)
      assert decoded["messages"] == [%{"role" => "user"}]
    end

    test "returns error for invalid data" do
      assert {:error, _} = Format.parse_python_json_hmac("not valid")
    end

    test "returns error for data too short" do
      assert {:error, _} = Format.parse_python_json_hmac("JSONV\x01\x00\x00")
    end
  end

  describe "normalize_name/1" do
    test "lowercases names" do
      assert Format.normalize_name("MySession") == "mysession"
    end

    test "replaces special characters with hyphens" do
      assert Format.normalize_name("hello@world#123") == "hello-world-123"
    end

    test "collapses multiple hyphens" do
      assert Format.normalize_name("a---b---c") == "a-b-c"
    end

    test "strips leading/trailing hyphens" do
      assert Format.normalize_name("-session-") == "session"
    end

    test "falls back to 'session' for empty result" do
      assert Format.normalize_name("!!!") == "session"
    end

    test "preserves dots and underscores (they become hyphens)" do
      assert Format.normalize_name("code_puppy.test") == "code-puppy-test"
    end
  end

  describe "build_paths/2" do
    test "builds session and metadata paths" do
      paths = Format.build_paths("/tmp/sessions", "my-session")

      assert paths.session_path == "/tmp/sessions/my-session.json"
      assert paths.metadata_path == "/tmp/sessions/my-session_meta.json"
    end

    test "normalizes the name in paths" do
      paths = Format.build_paths("/tmp/sessions", "My WEIRD Session!!!")

      assert paths.session_path == "/tmp/sessions/my-weird-session.json"
    end
  end
end
