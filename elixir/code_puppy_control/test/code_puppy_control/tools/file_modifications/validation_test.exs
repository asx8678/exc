defmodule CodePuppyControl.Tools.FileModifications.ValidationTest do
  @moduledoc "Tests for Validation — post-edit syntax validation (Elixir, Erlang, JSON only)."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.Validation

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "validation_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "validatable_extension?/1" do
    test "recognizes Elixir extensions" do
      assert Validation.validatable_extension?("/tmp/file.ex") == true
      assert Validation.validatable_extension?("/tmp/file.exs") == true
    end

    test "recognizes Erlang extensions" do
      assert Validation.validatable_extension?("/tmp/file.erl") == true
      assert Validation.validatable_extension?("/tmp/file.hrl") == true
    end

    test "recognizes JSON extension" do
      assert Validation.validatable_extension?("/tmp/file.json") == true
    end

    test "does NOT advertise validation for extensions without parsers" do
      # These have no actual validation logic in this module
      assert Validation.validatable_extension?("/tmp/file.py") == false
      assert Validation.validatable_extension?("/tmp/file.js") == false
      assert Validation.validatable_extension?("/tmp/file.ts") == false
      assert Validation.validatable_extension?("/tmp/file.tsx") == false
      assert Validation.validatable_extension?("/tmp/file.rs") == false
      assert Validation.validatable_extension?("/tmp/file.yaml") == false
      assert Validation.validatable_extension?("/tmp/file.yml") == false
      assert Validation.validatable_extension?("/tmp/file.toml") == false
    end

    test "rejects non-code extensions" do
      assert Validation.validatable_extension?("/tmp/file.txt") == false
      assert Validation.validatable_extension?("/tmp/file.md") == false
      assert Validation.validatable_extension?("/tmp/file.csv") == false
    end

    test "is case-insensitive" do
      assert Validation.validatable_extension?("/tmp/file.EX") == true
    end
  end

  describe "maybe_attach_warning/2" do
    test "skips validation for failed operations" do
      result = %{success: false, path: "/tmp/test.ex", message: "failed"}

      assert Validation.maybe_attach_warning(result, "/tmp/test.ex") == result
    end

    test "passes through for non-validatable extensions" do
      result = %{success: true, path: "/tmp/test.txt"}

      assert Validation.maybe_attach_warning(result, "/tmp/test.txt") == result
    end

    test "passes through for code extensions without parsers (fail-open)" do
      result = %{success: true, path: "/tmp/test.py"}

      assert Validation.maybe_attach_warning(result, "/tmp/test.py") == result
    end

    test "adds syntax_warning for invalid Elixir syntax", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid_test.ex")
      File.write!(path, "defmodule Foo do\n  def bar(\nend")

      result = %{success: true, path: path}
      result = Validation.maybe_attach_warning(result, path)

      assert Map.has_key?(result, :syntax_warning)
    end

    test "does not add warning for valid Elixir syntax", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid_test.ex")
      File.write!(path, "def foo, do: :bar")

      result = %{success: true, path: path}
      result = Validation.maybe_attach_warning(result, path)

      refute Map.has_key?(result, :syntax_warning)
    end
  end

  describe "validate_file/2" do
    test "returns :ok for non-validatable extensions (fail-open)" do
      assert {:ok, :valid} = Validation.validate_file("/tmp/test.txt", "anything")
      assert {:ok, :valid} = Validation.validate_file("/tmp/test.py", "print('hi')")
      assert {:ok, :valid} = Validation.validate_file("/tmp/test.js", "var x = 1")
    end

    test "validates valid Elixir code" do
      assert {:ok, :valid} = Validation.validate_file("/tmp/test.ex", "def foo, do: :bar")
    end

    test "detects invalid Elixir code" do
      assert {:warning, msg} =
               Validation.validate_file(
                 "/tmp/test.ex",
                 "defmodule Foo do\n  def bar(\nend"
               )

      assert msg =~ "Syntax error"
    end

    test "validates valid JSON" do
      assert {:ok, :valid} = Validation.validate_file("/tmp/test.json", ~s({"key": "value"}))
    end

    test "detects invalid JSON" do
      assert {:warning, msg} = Validation.validate_file("/tmp/test.json", "{invalid json")
      assert msg =~ "Invalid JSON"
    end

    test "validates valid Erlang code" do
      assert {:ok, :valid} =
               Validation.validate_file(
                 "/tmp/test.erl",
                 "-module(test).\n-export([foo/0]).\nfoo() -> ok."
               )
    end

    test "detects Erlang scan errors" do
      # 0x is an illegal integer token in Erlang
      assert {:warning, msg} =
               Validation.validate_file("/tmp/test.erl", "0x\n")

      assert msg =~ "scan error" or msg =~ "Erlang"
    end
  end

  describe "validation_enabled?/0" do
    test "returns a boolean" do
      assert is_boolean(Validation.validation_enabled?())
    end
  end
end
