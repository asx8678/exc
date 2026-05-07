defmodule CodePuppyControl.Parsing.ParserRegistryTest do
  @moduledoc """
  Tests for the ParserRegistry module.

  These tests verify that parsers can be registered, retrieved by language
  or extension, and properly unregistered.

  ## Python-as-data mock (allowlisted)

  `TestPythonParser` is a mock parser module used to test the registry
  dispatch. It exercises the ParserBehaviour contract, not real Python
  source parsing. Allowlisted per ADR-005.
  """
  use ExUnit.Case

  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.Parsing.ParserBehaviour

  # Test parser modules
  defmodule TestElixirParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(_source) do
      {:ok,
       %{
         language: "elixir",
         symbols: [],
         diagnostics: [],
         success: true,
         parse_time_ms: 0.1
       }}
    end

    @impl true
    def language, do: "elixir"

    @impl true
    def file_extensions, do: [".ex", ".exs"]

    @impl true
    def supported?, do: true
  end

  defmodule TestPythonParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(_source) do
      {:ok,
       %{
         language: "python",
         symbols: [],
         diagnostics: [],
         success: true,
         parse_time_ms: 0.1
       }}
    end

    @impl true
    def language, do: "python"

    @impl true
    def file_extensions, do: [".py", ".pyw"]

    @impl true
    def supported?, do: true
  end

  defmodule TestUnsupportedParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(_source), do: {:error, :unsupported}

    @impl true
    def language, do: "unsupported"

    @impl true
    def file_extensions, do: [".unsupported"]

    @impl true
    def supported?, do: false
  end

  defmodule IncompleteParser do
    # Missing required callbacks - only implements one
    def language, do: "incomplete"
  end

  setup do
    # Ensure registry is started (either by application or test supervision)
    # If already running (application supervision), clear its state
    # If not running, start it under test supervision
    case Process.whereis(ParserRegistry) do
      nil ->
        # Not running, start fresh
        start_supervised!(ParserRegistry)

      pid when is_pid(pid) ->
        # Running (likely from application supervision), clear state
        Agent.update(ParserRegistry, fn _ -> %{parsers: %{}, extensions: %{}} end)
    end

    :ok
  end

  describe "start_link/1" do
    test "starts the registry agent" do
      # Registry is already started in setup
      assert Process.whereis(ParserRegistry) != nil
    end
  end

  describe "register/1" do
    test "registers a supported parser module" do
      assert :ok = ParserRegistry.register(TestElixirParser)
    end

    test "returns error for unsupported parser" do
      assert {:error, :unsupported} = ParserRegistry.register(TestUnsupportedParser)
    end

    test "returns error for invalid module (missing callbacks)" do
      assert {:error, :invalid_module} = ParserRegistry.register(IncompleteParser)
    end

    test "multiple parsers can be registered" do
      assert :ok = ParserRegistry.register(TestElixirParser)
      assert :ok = ParserRegistry.register(TestPythonParser)

      assert {:ok, TestElixirParser} = ParserRegistry.get("elixir")
      assert {:ok, TestPythonParser} = ParserRegistry.get("python")
    end
  end

  describe "get/1" do
    test "returns parser for registered language" do
      ParserRegistry.register(TestElixirParser)

      assert {:ok, TestElixirParser} = ParserRegistry.get("elixir")
    end

    test "returns :error for unregistered language" do
      assert :error = ParserRegistry.get("unknown")
    end

    test "returns :error after parser is unregistered" do
      ParserRegistry.register(TestElixirParser)
      ParserRegistry.unregister("elixir")

      assert :error = ParserRegistry.get("elixir")
    end
  end

  describe "for_extension/1" do
    test "returns parser for registered extension" do
      ParserRegistry.register(TestElixirParser)

      assert {:ok, TestElixirParser} = ParserRegistry.for_extension(".ex")
      assert {:ok, TestElixirParser} = ParserRegistry.for_extension(".exs")
    end

    test "handles case-insensitive extensions" do
      ParserRegistry.register(TestPythonParser)

      assert {:ok, TestPythonParser} = ParserRegistry.for_extension(".PY")
      assert {:ok, TestPythonParser} = ParserRegistry.for_extension(".Py")
    end

    test "returns :error for unregistered extension" do
      assert :error = ParserRegistry.for_extension(".unknown")
    end
  end

  describe "list_languages/0" do
    test "returns empty list when no parsers registered" do
      assert ParserRegistry.list_languages() == []
    end

    test "returns list of registered languages" do
      ParserRegistry.register(TestElixirParser)
      ParserRegistry.register(TestPythonParser)

      languages = ParserRegistry.list_languages()
      assert length(languages) == 2
      assert {"elixir", TestElixirParser} in languages
      assert {"python", TestPythonParser} in languages
    end

    test "returns languages sorted alphabetically" do
      ParserRegistry.register(TestPythonParser)
      ParserRegistry.register(TestElixirParser)

      languages = ParserRegistry.list_languages()
      names = Enum.map(languages, fn {name, _} -> name end)
      assert names == ["elixir", "python"]
    end
  end

  describe "list_extensions/0" do
    test "returns empty list when no parsers registered" do
      assert ParserRegistry.list_extensions() == []
    end

    test "returns list of registered extensions" do
      ParserRegistry.register(TestElixirParser)

      extensions = ParserRegistry.list_extensions()
      assert {".ex", TestElixirParser} in extensions
      assert {".exs", TestElixirParser} in extensions
    end

    test "returns extensions sorted alphabetically" do
      ParserRegistry.register(TestPythonParser)
      ParserRegistry.register(TestElixirParser)

      extensions = ParserRegistry.list_extensions()
      exts = Enum.map(extensions, fn {ext, _} -> ext end)
      assert exts == [".ex", ".exs", ".py", ".pyw"]
    end
  end

  describe "unregister/1" do
    test "unregisters a parser by language name" do
      ParserRegistry.register(TestElixirParser)
      assert :ok = ParserRegistry.unregister("elixir")

      assert :error = ParserRegistry.get("elixir")
    end

    test "removes associated extensions" do
      ParserRegistry.register(TestElixirParser)
      ParserRegistry.unregister("elixir")

      assert :error = ParserRegistry.for_extension(".ex")
      assert :error = ParserRegistry.for_extension(".exs")
    end

    test "returns :ok even for unregistered language" do
      assert :ok = ParserRegistry.unregister("nonexistent")
    end

    test "preserves other parsers when unregistering" do
      ParserRegistry.register(TestElixirParser)
      ParserRegistry.register(TestPythonParser)
      ParserRegistry.unregister("elixir")

      assert {:ok, TestPythonParser} = ParserRegistry.get("python")
    end
  end

  describe "clear/0" do
    test "removes all registered parsers" do
      ParserRegistry.register(TestElixirParser)
      ParserRegistry.register(TestPythonParser)
      assert :ok = ParserRegistry.clear()

      assert ParserRegistry.list_languages() == []
      assert ParserRegistry.list_extensions() == []
    end
  end
end
