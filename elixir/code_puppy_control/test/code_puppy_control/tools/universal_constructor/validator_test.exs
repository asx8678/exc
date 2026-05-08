defmodule CodePuppyControl.Tools.UniversalConstructor.ValidatorTest do
  @moduledoc """
  Tests for the Universal Constructor Validator module.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.UniversalConstructor.Validator

  describe "validate_syntax/1" do
    test "accepts valid Elixir code" do
      code = """
      defmodule ValidModule do
        def run(args) do
          {:ok, args}
        end
      end
      """

      result = Validator.validate_syntax(code)

      assert result.valid == true
      assert result.errors == []
      assert length(result.functions) == 1

      [func] = result.functions
      assert func.name == :run
      assert func.arity == 1
    end

    test "rejects code with syntax errors" do
      code = """
      defmodule BadModule do
        def run(args)  # missing 'do' and 'end'
      """

      result = Validator.validate_syntax(code)

      assert result.valid == false
      assert length(result.errors) >= 1
      assert hd(result.errors) =~ "Syntax error"
    end

    test "extracts multiple function definitions" do
      code = """
      defmodule MultiFunc do
        def run(args), do: :ok
        def helper(x, y), do: x + y
        def process(), do: nil
      end
      """

      result = Validator.validate_syntax(code)

      assert result.valid == true
      assert length(result.functions) == 3

      func_names = Enum.map(result.functions, & &1.name)
      assert :run in func_names
      assert :helper in func_names
      assert :process in func_names
    end
  end

  describe "extract_function_info/1" do
    test "returns same result as validate_syntax" do
      code = "defmodule X do def run(_), do: nil end"

      syntax_result = Validator.validate_syntax(code)
      func_result = Validator.extract_function_info(code)

      assert syntax_result == func_result
    end
  end

  describe "check_safety/1" do
    test "marks code with System.cmd as unsafe" do
      code = """
      defmodule Dangerous do
        @uc_tool %{name: "danger", description: "Dangerous"}
        def run(_args) do
          System.cmd("rm", ["-rf", "/"])
        end
      end
      """

      result = Validator.check_safety(code)

      assert result.safe == false
      assert result.dangerous_patterns != []
      assert "System.cmd" in result.dangerous_patterns
    end

    test "allows safe code" do
      code = """
      defmodule SafeTool do
        @uc_tool %{name: "safe", description: "Safe"}
        def run(args) do
          Enum.map(args, &String.upcase/1)
        end
      end
      """

      result = Validator.check_safety(code)

      assert result.safe == true
      assert result.dangerous_patterns == []
    end

    test "cannot check safety on invalid syntax" do
      # incomplete
      code = "defmodule X do def run("

      result = Validator.check_safety(code)

      assert result.safe == false
      assert result.warnings != []
    end
  end

  describe "full_validation/1" do
    test "combines syntax and safety checks" do
      code = """
      defmodule FullTest do
        @uc_tool %{name: "full", description: "Full test"}
        def run(args) do
          {:ok, args}
        end
      end
      """

      result = Validator.full_validation(code)

      assert result.valid == true
      assert result.errors == []
      assert length(result.functions) == 1
    end

    test "marks unsafe code as invalid" do
      code = """
      defmodule UnsafeTest do
        @uc_tool %{name: "unsafe", description: "Unsafe test"}
        def run(_args) do
          System.shell("echo danger")
        end
      end
      """

      result = Validator.full_validation(code)

      assert result.valid == false
      assert result.errors != []
      assert hd(result.errors) =~ "Dangerous patterns"
    end
  end

  describe "validate_tool_meta/1" do
    test "requires name field" do
      errors = Validator.validate_tool_meta(%{description: "Test"})

      assert errors != []
      assert hd(errors) =~ "name"
    end

    test "requires description field" do
      errors = Validator.validate_tool_meta(%{name: "test"})

      assert errors != []
      assert hd(errors) =~ "description"
    end

    test "returns empty list for valid meta" do
      errors =
        Validator.validate_tool_meta(%{
          name: "test",
          description: "A test tool"
        })

      assert errors == []
    end

    test "detects empty string values" do
      errors =
        Validator.validate_tool_meta(%{
          name: "",
          description: ""
        })

      assert length(errors) == 2
    end
  end

  describe "extract_uc_tool_meta/1" do
    test "extracts simple @uc_tool map" do
      code = """
      defmodule ExtractTest do
        @uc_tool %{
          name: "extract",
          description: "Extract test",
          version: "1.0.0"
        }
        def run(_), do: nil
      end
      """

      assert {:ok, meta} = Validator.extract_uc_tool_meta(code)
      assert meta[:name] == "extract"
      assert meta[:description] == "Extract test"
      assert meta[:version] == "1.0.0"
    end

    test "handles compact single-line format" do
      code = """
      defmodule CompactTest do
        @uc_tool %{name: "compact", description: "Compact"}
        def run(_), do: nil
      end
      """

      assert {:ok, meta} = Validator.extract_uc_tool_meta(code)
      assert meta[:name] == "compact"
    end

    test "returns error for missing @uc_tool" do
      code = """
      defmodule NoMeta do
        def run(_), do: nil
      end
      """

      assert {:error, _} = Validator.extract_uc_tool_meta(code)
    end

    test "returns error for empty module" do
      assert {:error, _} = Validator.extract_uc_tool_meta("")
    end
  end

  describe "generate_preview/2" do
    test "returns full code when under max_lines" do
      code = "line1\nline2\nline3"

      preview = Validator.generate_preview(code, 5)

      assert preview == code
    end

    test "truncates code over max_lines" do
      code = "line1\nline2\nline3\nline4\nline5"

      preview = Validator.generate_preview(code, 3)

      assert preview == "line1\nline2\nline3\n... (truncated)"
    end

    test "defaults to 10 lines" do
      code = Enum.map_join(1..15, "\n", &"line#{&1}")

      preview = Validator.generate_preview(code)

      assert preview =~ "... (truncated)"
      # 10 + truncation marker
      assert String.split(preview, "\n") |> length() == 11
    end
  end

  describe "find_main_function/2" do
    test "finds function matching tool name" do
      functions = [
        %{name: :helper, arity: 1},
        %{name: :weather, arity: 1},
        %{name: :run, arity: 1}
      ]

      result = Validator.find_main_function(functions, "weather")

      assert result.name == :weather
    end

    test "falls back to :run" do
      functions = [
        %{name: :helper, arity: 1},
        %{name: :run, arity: 2}
      ]

      result = Validator.find_main_function(functions, "my_tool")

      assert result.name == :run
    end

    test "falls back to :execute" do
      functions = [
        %{name: :helper, arity: 0},
        %{name: :execute, arity: 1}
      ]

      result = Validator.find_main_function(functions, "my_tool")

      assert result.name == :execute
    end

    test "returns nil when no match" do
      functions = [%{name: :private_helper, arity: 1}]

      result = Validator.find_main_function(functions, "my_tool")

      assert result == nil
    end

    # Regression: code_puppy-mmk.2 — arbitrary tool names must NOT create atoms
    test "does not create new atoms for arbitrary tool_name values" do
      # Generate a name that is practically guaranteed NOT to exist as an atom.
      # If String.to_atom were used, this would leak a new atom.
      unique_name = "never_an_atom_#{:erlang.unique_integer([:positive])}"

      # Ensure it's not already an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_name) end

      functions = [
        %{name: :run, arity: 1}
      ]

      # This call should NOT create the atom; it should fall through to :run
      result = Validator.find_main_function(functions, unique_name)
      assert result.name == :run

      # Verify the atom was NOT created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_name) end
    end

    test "matches function by string comparison even when atom exists" do
      # :run already exists as an atom, so matching it by name "run" works
      functions = [
        %{name: :run, arity: 1},
        %{name: :execute, arity: 1}
      ]

      result = Validator.find_main_function(functions, "run")
      assert result.name == :run
    end
  end

  describe "safe_parse_literal_map/1" do
    test "accepts valid literal map" do
      assert {:ok, %{name: "my_tool", description: "desc"}} =
               Validator.safe_parse_literal_map(~s|%{name: "my_tool", description: "desc"}|)
    end

    test "rejects map with function calls" do
      assert {:error, _} =
               Validator.safe_parse_literal_map(~s|%{name: System.cmd("curl", ["evil.com"])}|)
    end

    test "rejects map with variable references" do
      assert {:error, _} = Validator.safe_parse_literal_map(~s|%{name: some_var}|)
    end

    test "rejects completely invalid syntax" do
      assert {:error, _} = Validator.safe_parse_literal_map("not a map at all")
    end
  end
end
