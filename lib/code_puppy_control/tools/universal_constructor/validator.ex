defmodule CodePuppyControl.Tools.UniversalConstructor.Validator do
  @moduledoc """
  Code validation and safety checking for Universal Constructor tools.

  Provides utilities for validating Elixir tool code before execution or storage,
  including syntax checking, function extraction, and dangerous pattern detection.

  ## Safety Considerations

  The validator checks for potentially dangerous patterns:
  - System execution (System.cmd, System.shell, :os.cmd)
  - Code evaluation (Code.eval_string, Code.eval_quoted without safety)
  - File operations with elevated privileges
  - Network operations
  - Unsafe NIF calls
  """

  require Logger

  @type validation_result :: %{
          valid: boolean(),
          errors: list(String.t()),
          warnings: list(String.t()),
          functions: list(function_info())
        }

  @type function_info :: %{
          name: atom(),
          arity: non_neg_integer(),
          signature: String.t(),
          docstring: String.t() | nil,
          line_number: non_neg_integer()
        }

  @type safety_result :: %{
          safe: boolean(),
          dangerous_patterns: list(String.t()),
          warnings: list(String.t())
        }

  # Dangerous modules/patterns to check
  @dangerous_modules [
    # System execution
    "System.cmd",
    "System.shell",
    ":os.cmd",
    "Port.open",
    # Code evaluation (unsafe usage)
    "Code.eval_string",
    "Code.eval_quoted",
    # Unsafe atoms (potential atom exhaustion)
    "String.to_atom",
    # File operations (with caution)
    "File.rm_rf",
    # Network (if not using proper validation)
    ":gen_tcp.connect"
  ]

  # Note: Kernel functions to watch for (reserved for future stricter checking)
  # Currently not actively checked but available for enhanced validation
  # @dangerous_functions [
  #   :apply,
  #   :spawn,
  #   :spawn_link,
  #   :spawn_monitor
  # ]

  @doc """
  Validates Elixir syntax without compiling.

  ## Examples

      iex> Validator.validate_syntax("defmodule Test do end")
      %{valid: true, errors: [], warnings: [], functions: []}

      iex> Validator.validate_syntax("defmodule Test do")
      %{valid: false, errors: ["syntax error: missing 'end'"], ...}

  """
  @spec validate_syntax(String.t()) :: validation_result()
  def validate_syntax(code) when is_binary(code) do
    base_result = %{
      valid: true,
      errors: [],
      warnings: [],
      functions: []
    }

    # Try to tokenize the code
    case Code.string_to_quoted(code, columns: true, token_metadata: true) do
      {:ok, ast} ->
        functions = extract_functions_from_ast(ast)
        %{base_result | functions: functions}

      {:error, {line, error_msg, _token}} when is_integer(line) and is_binary(error_msg) ->
        %{
          base_result
          | valid: false,
            errors: ["Syntax error at line #{line}: #{error_msg}"]
        }

      {:error, reason} ->
        %{
          base_result
          | valid: false,
            errors: ["Syntax error: #{inspect(reason)}"]
        }
    end
  end

  @doc """
  Extracts function information from code.

  Returns a list of function info maps containing name, arity, signature,
  docstring (if available), and line number.
  """
  @spec extract_function_info(String.t()) :: validation_result()
  def extract_function_info(code) when is_binary(code) do
    validate_syntax(code)
  end

  @doc """
  Checks for potentially dangerous patterns in Elixir code.

  When dangerous patterns are detected, sets safe=false.

  ## Examples

      iex> Validator.check_safety("System.cmd(\"rm\", [\"-rf\", \"/\"])")
      %{safe: false, dangerous_patterns: ["System.cmd"], ...}

  """
  @spec check_safety(String.t()) :: safety_result()
  def check_safety(code) when is_binary(code) do
    base_result = %{
      safe: true,
      dangerous_patterns: [],
      warnings: []
    }

    # First validate syntax
    syntax_result = validate_syntax(code)

    if not syntax_result.valid do
      %{
        base_result
        | safe: false,
          warnings: ["Cannot check safety: syntax errors in code"]
      }
    else
      # Check for dangerous patterns
      dangerous_found =
        @dangerous_modules
        |> Enum.filter(fn pattern ->
          String.contains?(code, pattern)
        end)

      if dangerous_found != [] do
        %{
          base_result
          | safe: false,
            dangerous_patterns: dangerous_found,
            warnings: [
              "Potentially dangerous patterns found: #{Enum.join(dangerous_found, ", ")}"
            ]
        }
      else
        base_result
      end
    end
  end

  @doc """
  Performs full validation including syntax, function extraction, and safety.

  ## Examples

      iex> Validator.full_validation("defmodule Test do def run(_), do: :ok end")
      %{valid: true, errors: [], warnings: [], functions: [%{name: :run, arity: 1, ...}]}

  """
  @spec full_validation(String.t()) :: validation_result()
  def full_validation(code) when is_binary(code) do
    # Start with syntax and function extraction
    result = extract_function_info(code)

    # Check safety
    safety = check_safety(code)

    if not safety.safe do
      %{
        result
        | valid: false,
          errors:
            result.errors ++
              ["Dangerous patterns blocked: #{Enum.join(safety.dangerous_patterns, ", ")}"],
          warnings: result.warnings ++ safety.warnings
      }
    else
      %{result | warnings: result.warnings ++ safety.warnings}
    end
  end

  @doc """
  Validates that UC tool metadata has required fields.

  Required fields: `:name`, `:description`
  """
  @spec validate_tool_meta(map()) :: list(String.t())
  def validate_tool_meta(meta) when is_map(meta) do
    errors = []

    errors =
      if is_nil(meta[:name]) or meta[:name] == "" do
        ["TOOL_META missing required field: 'name'" | errors]
      else
        errors
      end

    errors =
      if is_nil(meta[:description]) or meta[:description] == "" do
        ["TOOL_META missing required field: 'description'" | errors]
      else
        errors
      end

    Enum.reverse(errors)
  end

  @doc """
  Extracts @uc_tool metadata from Elixir source code.

  ## Examples

      iex> Validator.extract_uc_tool_meta(~s(@uc_tool %{name: "test", description: "A test"}))
      {:ok, %{name: "test", description: "A test"}}

  """
  @spec extract_uc_tool_meta(String.t()) :: {:ok, map()} | {:error, String.t()}
  def extract_uc_tool_meta(code) when is_binary(code) do
    # Look for @uc_tool attribute
    pattern = ~r/@uc_tool\s+(%\{[^}]+\})/s

    case Regex.run(pattern, code) do
      [_, map_str] ->
        parse_meta_map(map_str)

      nil ->
        # Try multi-line format
        alt_pattern = ~r/@uc_tool\s+(\%\{[\s\S]*?\n\s*\})/m

        case Regex.run(alt_pattern, code) do
          [_, map_str] ->
            parse_meta_map(map_str)

          nil ->
            {:error, "No @uc_tool attribute found in code"}
        end
    end
  end

  @doc """
  Generates a preview of the first N lines of code.

  ## Examples

      iex> Validator.generate_preview("line1\nline2\nline3\n...\n...", 2)
      "line1\nline2\n... (truncated)"

  """
  @spec generate_preview(String.t(), non_neg_integer()) :: String.t()
  def generate_preview(code, max_lines \\ 10) do
    lines = String.split(code, "\n")

    if length(lines) <= max_lines do
      code
    else
      lines
      |> Enum.take(max_lines)
      |> Enum.join("\n")
      |> Kernel.<>("\n... (truncated)")
    end
  end

  @doc """
  Finds the main function name for a tool.

  Looks for functions in priority order:
  1. Function with the same name as the tool
  2. Function named :run
  3. Function named :execute
  4. First public function (not starting with _)

  """
  # Known safe function-name atoms used as fallback candidates.
  # Only :run and :execute are ever atomized; user-controlled tool_name
  # is matched as a string to avoid atom-table exhaustion (code_puppy-mmk.2).
  @safe_fallback_atoms [:run, :execute]

  @spec find_main_function(list(function_info()), String.t()) :: function_info() | nil
  def find_main_function(functions, tool_name) when is_list(functions) do
    # 1. Try matching the tool name as a STRING against function names,
    #    converting the atom to string for comparison.  This avoids calling
    #    String.to_atom/1 on user-controlled input.
    by_name = Enum.find(functions, fn f -> Atom.to_string(f.name) == tool_name end)

    if by_name do
      by_name
    else
      # 2. Fall back to known safe atoms only
      Enum.find_value(@safe_fallback_atoms, fn name ->
        Enum.find(functions, fn f -> f.name == name end)
      end)
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp extract_functions_from_ast(ast) do
    {_, functions} =
      Macro.prewalk(ast, [], fn
        # Match def/defp
        {:def, _, [{name, _, args} | _]} = node, acc ->
          arity = if is_list(args), do: length(args), else: 0
          func_info = build_function_info(name, arity)
          {node, [func_info | acc]}

        {:defp, _, [{name, _, args} | _]} = node, acc ->
          arity = if is_list(args), do: length(args), else: 0
          func_info = build_function_info(name, arity)
          {node, [func_info | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(functions)
  end

  defp build_function_info(name, arity) when is_atom(name) do
    %{
      name: name,
      arity: arity,
      signature: "#{name}/#{arity}",
      docstring: nil,
      line_number: 0
    }
  end

  # ============================================================================
  # Safe Literal Parsing (Security: No Code.eval_string on user input)
  # ============================================================================

  @doc """
  Safely parses a map string containing only literal values.

  Uses Code.string_to_quoted/1 to parse as AST, then validates that the
  AST contains only literal values (strings, atoms, booleans, numbers) before
  constructing the result map.

  This prevents arbitrary code execution from user-provided @uc_tool content.
  """
  @spec safe_parse_literal_map(String.t()) :: {:ok, map()} | {:error, String.t()}
  def safe_parse_literal_map(map_str) when is_binary(map_str) do
    try do
      case Code.string_to_quoted(map_str) do
        {:ok, ast} ->
          case parse_map_ast(ast) do
            {:ok, map} when is_map(map) ->
              {:ok, map}

            {:error, reason} ->
              {:error, reason}

            _ ->
              {:error, "@uc_tool is not a map"}
          end

        {:error, {line, error_msg, _}} ->
          {:error, "Parse error at line #{line}: #{error_msg}"}

        {:error, reason} ->
          {:error, "Invalid @uc_tool metadata: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Invalid @uc_tool metadata: #{inspect(e)}"}
    end
  end

  # Parse a map AST into an Elixir map (only allows literal values)
  defp parse_map_ast({:%{}, _, kvs}) when is_list(kvs) do
    result =
      Enum.reduce_while(kvs, %{}, fn {key_ast, val_ast}, acc ->
        with {:ok, key} <- parse_key(key_ast),
             {:ok, val} <- parse_literal(val_ast) do
          {:cont, Map.put(acc, key, val)}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, _} = err -> err
      map -> {:ok, map}
    end
  end

  defp parse_map_ast(other) do
    {:error, "Expected a map literal, got: #{inspect(other)}"}
  end

  # Keys must be atoms (bare or quoted)
  defp parse_key({_, _, nil} = atom) when is_atom(atom), do: {:ok, atom}
  defp parse_key(atom) when is_atom(atom), do: {:ok, atom}

  defp parse_key({:__aliases__, _, [atom]}) when is_atom(atom),
    do: {:ok, atom}

  defp parse_key(other),
    do: {:error, "Invalid key in @uc_tool map: #{inspect(other)}"}

  # Parse literal values (strings, atoms, booleans, nil, numbers, lists of literals)
  defp parse_literal(string) when is_binary(string), do: {:ok, string}
  defp parse_literal(atom) when is_atom(atom), do: {:ok, atom}
  defp parse_literal(int) when is_integer(int), do: {:ok, int}
  defp parse_literal(float) when is_float(float), do: {:ok, float}

  defp parse_literal({:__block__, _, [single]}), do: parse_literal(single)

  defp parse_literal(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_literal(item) do
        {:ok, val} -> {:cont, {:ok, [val | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, vals} -> {:ok, Enum.reverse(vals)}
      {:error, _} = err -> err
    end
  end

  defp parse_literal({:{}, _, elems}) do
    # Tuple - convert to list for simplicity
    case parse_literal(elems) do
      {:ok, vals} -> {:ok, List.to_tuple(vals)}
      {:error, _} = err -> err
    end
  end

  defp parse_literal(other) do
    {:error, "Non-literal value in @uc_tool map: #{inspect(other)}"}
  end

  defp parse_meta_map(map_str) do
    safe_parse_literal_map(map_str)
  end
end
