defmodule CodePuppyControl.HookEngine.Matcher do
  @moduledoc """
  Pattern matching engine for hook filters.

  Provides flexible pattern matching to determine if a hook should execute
  based on tool name, arguments, and other event data.

  Ported from `code_puppy/hook_engine/matcher.py`.

  ## Matcher Syntax

  - `"*"` — Matches all tools
  - `"ToolName"` — Exact tool name match (case-insensitive)
  - `".ext"` — File extension match (e.g., ".py", ".ts")
  - `"Pattern1 && Pattern2"` — AND condition (all must match)
  - `"Pattern1 || Pattern2"` — OR condition (any must match)
  """

  alias CodePuppyControl.HookEngine.Aliases

  # ReDoS protection pattern
  @dangerous_pattern ~r/\([^)]*[+*][^)]*\)[+*]|[+*]\w[+*]|\([^)]*\|[^)]*\)[+*]/

  @doc """
  Evaluates if a matcher pattern matches the tool call.

  ## Examples

      iex> CodePuppyControl.HookEngine.Matcher.matches("*", "agent_run_shell_command", %{})
      true

      iex> CodePuppyControl.HookEngine.Matcher.matches("Bash", "agent_run_shell_command", %{})
      true

      iex> CodePuppyControl.HookEngine.Matcher.matches(".py || .ts", "read_file", %{"file_path" => "main.py"})
      true

      iex> CodePuppyControl.HookEngine.Matcher.matches("Unknown", "agent_run_shell_command", %{})
      false
  """
  @spec matches(String.t() | nil, String.t(), map()) :: boolean()
  def matches(nil, _tool_name, _tool_args), do: false
  def matches("", _tool_name, _tool_args), do: false
  def matches("*", _tool_name, _tool_args), do: true

  def matches(matcher, tool_name, tool_args) when is_binary(matcher) do
    cond do
      String.contains?(matcher, "||") ->
        matcher
        |> String.split("||")
        |> Stream.map(&String.trim/1)
        |> Enum.any?(&matches(&1, tool_name, tool_args))

      String.contains?(matcher, "&&") ->
        matcher
        |> String.split("&&")
        |> Stream.map(&String.trim/1)
        |> Enum.all?(&matches(&1, tool_name, tool_args))

      true ->
        match_single(String.trim(matcher), tool_name, tool_args)
    end
  end

  @doc """
  Extracts a file path from tool arguments.

  Checks common file path keys in order, then scans values for
  ones that look like file paths.
  """
  @spec extract_file_path(map()) :: String.t() | nil
  def extract_file_path(tool_args) when is_map(tool_args) do
    file_keys =
      ~w(file_path file path target input_file output_file source destination src dest filename)

    result =
      Enum.find_value(file_keys, fn key ->
        case Map.get(tool_args, key) do
          value when is_binary(value) -> value
          _ -> nil
        end
      end)

    result ||
      Enum.find_value(tool_args, fn
        {_key, value} when is_binary(value) ->
          if looks_like_file_path(value), do: value

        _ ->
          nil
      end)
  end

  def extract_file_path(_tool_args), do: nil

  @doc """
  Returns true if the given value looks like a file path.
  """
  @spec looks_like_file_path(String.t()) :: boolean()
  def looks_like_file_path(value) when is_binary(value) do
    cond do
      value == "" ->
        false

      String.contains?(value, ".") and not String.starts_with?(value, ".") ->
        parts = String.split(value, ".")

        length(parts) >= 2 and
          String.length(List.last(parts)) <= 10 and
          String.printable?(List.last(parts))

      String.contains?(value, "/") or String.contains?(value, "\\") ->
        true

      true ->
        false
    end
  end

  def looks_like_file_path(_value), do: false

  @doc """
  Extracts file extension from a file path.

  ## Examples

      iex> CodePuppyControl.HookEngine.Matcher.extract_file_extension("main.py")
      ".py"

      iex> CodePuppyControl.HookEngine.Matcher.extract_file_extension("/path/to/main.ts")
      ".ts"

      iex> CodePuppyControl.HookEngine.Matcher.extract_file_extension("noext")
      nil
  """
  @spec extract_file_extension(String.t()) :: String.t() | nil
  def extract_file_extension(file_path) when is_binary(file_path) do
    basename = file_path |> String.split(~r{[/\\]}) |> List.last()

    case basename do
      nil ->
        nil

      name when is_binary(name) ->
        case String.split(name, ".") do
          [^name] -> nil
          parts -> "." <> List.last(parts)
        end

      _ ->
        nil
    end
  end

  def extract_file_extension(_file_path), do: nil

  @doc """
  Matches a tool name against a list of names (case-insensitive).
  """
  @spec matches_tool(String.t(), [String.t()]) :: boolean()
  def matches_tool(tool_name, names) when is_binary(tool_name) and is_list(names) do
    Enum.any?(names, fn name ->
      String.downcase(tool_name) == String.downcase(name)
    end)
  end

  @doc """
  Returns true if the tool args reference a file with one of the given extensions.
  """
  @spec matches_file_extension(map(), [String.t()]) :: boolean()
  def matches_file_extension(tool_args, extensions)
      when is_map(tool_args) and is_list(extensions) do
    case extract_file_path(tool_args) do
      nil -> false
      path -> extract_file_extension(path) in extensions
    end
  end

  @doc """
  Returns true if the tool args reference a file matching the given regex pattern.
  """
  @spec matches_file_pattern(map(), String.t()) :: boolean()
  def matches_file_pattern(tool_args, pattern) when is_map(tool_args) and is_binary(pattern) do
    case extract_file_path(tool_args) do
      nil -> false
      path -> safe_regex_match(pattern, path)
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  @spec match_single(String.t(), String.t(), map()) :: boolean()
  defp match_single(pattern, tool_name, tool_args) do
    cond do
      pattern == tool_name ->
        true

      String.downcase(pattern) == String.downcase(tool_name) ->
        true

      # Alias match — cross-provider tool name aliases
      not MapSet.disjoint?(Aliases.get_aliases(tool_name), Aliases.get_aliases(pattern)) ->
        true

      # Regex pattern match (advanced metacharacters: ^, $, +, ?, etc.)
      # Must come BEFORE file-extension and wildcard checks so patterns
      # like `^agent_.*` and `.*\.py$` are treated as regex, not glob.
      is_regex_pattern?(pattern) ->
        safe_regex_match(pattern, tool_name) ||
          case extract_file_path(tool_args) do
            nil -> false
            path -> safe_regex_match(pattern, path)
          end

      # File extension match (.py, .ts, etc.) — only simple extensions
      # Patterns with regex metacharacters are handled above.
      String.starts_with?(pattern, ".") ->
        case extract_file_path(tool_args) do
          nil -> false
          path -> String.ends_with?(path, pattern)
        end

      # Simple wildcard/glob match (only `*` metacharacter)
      String.contains?(pattern, "*") ->
        parts = String.split(pattern, "*")
        regex_str = Enum.map_join(parts, ".*", &Regex.escape/1)
        safe_regex_match("^#{regex_str}$", tool_name)

      true ->
        false
    end
  end

  @spec safe_regex_match(String.t(), String.t()) :: boolean()
  defp safe_regex_match(pattern, text) do
    if is_safe_pattern?(pattern) do
      case Regex.compile(pattern, [:caseless, :unicode]) do
        {:ok, regex} -> Regex.match?(regex, text)
        {:error, _} -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  @spec is_safe_pattern?(String.t()) :: boolean()
  defp is_safe_pattern?(pattern) when is_binary(pattern) do
    not Regex.match?(@dangerous_pattern, pattern)
  end

  defp is_safe_pattern?(_pattern), do: false

  # Metacharacters that indicate regex semantics (not glob).
  # Excludes `*` because `*` is handled separately as a glob/wildcard.
  # Includes `.` only when it appears in regex context (`.*` or `\.`).
  # Cannot use ~w sigil due to special characters — plain list required.
  @regex_metacharacters ["^", "$", "+", "?", "{", "}", "[", "]", "(", ")", "|", "\\"]

  @spec is_regex_pattern?(String.t()) :: boolean()
  defp is_regex_pattern?(pattern) do
    Enum.any?(@regex_metacharacters, &String.contains?(pattern, &1)) or
      regex_dot?(pattern)
  end

  # A dot is a regex metacharacter when it appears in regex context:
  #   `.*` — zero-or-more-any
  #   `\.` — escaped literal dot (single backslash + dot)
  # Standalone dots (e.g. in file paths like `main.py`) are NOT
  # treated as regex because they're handled by file-extension matching
  # or exact-name matching earlier in `match_single`.
  @spec regex_dot?(String.t()) :: boolean()
  defp regex_dot?(pattern) do
    String.contains?(pattern, ".*") or String.contains?(pattern, "\\.")
  end
end
