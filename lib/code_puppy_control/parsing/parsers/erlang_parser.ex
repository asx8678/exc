defmodule CodePuppyControl.Parsing.Parsers.ErlangParser do
  @moduledoc """
  Erlang parser using :erl_scan and :erl_parse from OTP.

  Extracts: modules, functions, records, types, specs.
  """
  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  @impl true
  def language, do: "erlang"

  @impl true
  def file_extensions, do: [".erl", ".hrl"]

  @impl true
  def supported?, do: true

  @impl true
  def parse(source) when is_binary(source) do
    start = System.monotonic_time(:millisecond)
    charlist = String.to_charlist(source)

    case :erl_scan.string(charlist, 1, [:text]) do
      {:ok, tokens, _} ->
        # Extract symbols from tokens
        symbols = extract_symbols_from_tokens(tokens)

        # Check for obvious syntax issues that the scanner allows through
        # but would cause parse errors
        diagnostics = detect_syntax_issues(tokens)
        success = diagnostics == []

        end_time = System.monotonic_time(:millisecond)

        {:ok,
         %{
           language: "erlang",
           symbols: symbols,
           diagnostics: diagnostics,
           success: success,
           parse_time_ms: end_time - start
         }}

      {:error, {line, _module, error}, _} ->
        end_time = System.monotonic_time(:millisecond)

        {:ok,
         %{
           language: "erlang",
           symbols: [],
           diagnostics: [
             %{
               line: line,
               column: 1,
               message: to_string(:erl_scan.format_error(error)),
               severity: :error
             }
           ],
           success: false,
           parse_time_ms: end_time - start
         }}
    end
  end

  # Detect obvious syntax issues from tokens
  # - Check for malformed attribute patterns (e.g., missing closing paren)
  defp detect_syntax_issues(tokens) do
    # Check each line for balanced parentheses in attributes
    line_groups =
      Enum.reduce(tokens, %{}, fn token, acc ->
        line = get_token_line(token)
        Map.update(acc, line, [token], &[token | &1])
      end)
      |> Enum.map(fn {line, tokens} -> {line, Enum.reverse(tokens)} end)
      |> Enum.sort_by(fn {line, _} -> line end)

    Enum.flat_map(line_groups, fn {line, line_tokens} ->
      check_line_syntax(line, line_tokens)
    end)
  end

  # Check a single line for syntax issues
  defp check_line_syntax(line, line_tokens) do
    token_types = Enum.map(line_tokens, &token_type/1)

    issues = []

    # Check for attribute without closing paren: -name(value.
    issues =
      if attribute_pattern?(token_types) and not has_closing_paren?(token_types) do
        [%{line: line, column: 1, message: "missing closing ')'", severity: :error} | issues]
      else
        issues
      end

    # Check for unbalanced @ usage (standalone @ token followed by invalid atom)
    issues =
      if has_standalone_at?(line_tokens, token_types) do
        [%{line: line, column: 1, message: "invalid token: @", severity: :error} | issues]
      else
        issues
      end

    issues
  end

  defp attribute_pattern?(types) do
    # -name(... pattern (attribute start)
    :- in types and :atom in types and :"(" in types
  end

  defp has_closing_paren?(types) do
    :")" in types
  end

  defp has_standalone_at?(_tokens, types) do
    # Look for @ token in contexts where it's likely invalid
    # In module attributes like -module(@invalid), @ is not allowed
    at_positions =
      Enum.with_index(types)
      |> Enum.filter(fn {type, _idx} -> type == :@ end)
      |> Enum.map(fn {_, idx} -> idx end)

    Enum.any?(at_positions, fn at_idx ->
      # Check what follows @
      next_type = Enum.at(types, at_idx + 1)

      cond do
        # @ not followed by anything - definitely invalid
        next_type == nil ->
          true

        # @ followed by atom can be valid in some contexts (macros),
        # but invalid in others (like inside -module())
        # Check if we're inside an attribute value (after '(' but before ')')
        next_type == :atom and inside_attribute_value?(types, at_idx) ->
          # @ inside attribute value is likely invalid
          true

        # @ followed by non-atom/non-var is invalid
        next_type not in [:atom, :var, :integer] ->
          true

        true ->
          false
      end
    end)
  end

  # Check if an @ at given position is inside an attribute value context
  # (after '(' but before ')' on the same line/attribute)
  defp inside_attribute_value?(types, at_idx) do
    # Look backwards to see if we have '(' before us (and no ')' in between)
    prefix = Enum.take(types, at_idx)
    suffix = Enum.drop(types, at_idx + 1)

    has_open_paren_before = :"(" in prefix
    has_close_paren_before = :")" in prefix
    has_close_paren_after = :")" in suffix

    # We're inside parens if we have an open before us and no close before us,
    # but there is a close after us
    has_open_paren_before and not has_close_paren_before and has_close_paren_after
  end

  # ---------------------------------------------------------------------------
  # Symbol Extraction from Tokens
  # ---------------------------------------------------------------------------

  defp extract_symbols_from_tokens(tokens) do
    tokens
    |> group_tokens_by_lines()
    |> extract_declarations()
    |> Enum.reverse()
  end

  # Group tokens by their line number for easier processing
  defp group_tokens_by_lines(tokens) do
    Enum.reduce(tokens, %{}, fn token, acc ->
      line = get_token_line(token)
      Map.update(acc, line, [token], &[token | &1])
    end)
    |> Enum.map(fn {line, tokens} -> {line, Enum.reverse(tokens)} end)
    |> Enum.sort_by(fn {line, _} -> line end)
  end

  defp get_token_line(token) do
    case token do
      # Standard format without :text option
      {_, {line, _}, _} ->
        line

      {_, {line, _}} ->
        line

      # Format with [:text] option - location in keyword list
      {_, meta, _} when is_list(meta) ->
        Keyword.get(meta, :location, 0)

      {_, meta} when is_list(meta) ->
        Keyword.get(meta, :location, 0)

      _ ->
        0
    end
  end

  defp extract_declarations(line_groups) do
    {symbols, _current_module} =
      Enum.reduce(line_groups, {[], nil}, fn {line, tokens}, {acc, current_module} ->
        extract_from_line(tokens, line, acc, current_module)
      end)

    symbols
  end

  defp extract_from_line(tokens, line, acc, current_module) do
    # Flatten tokens to check for patterns
    token_types = Enum.map(tokens, &token_type/1)

    cond do
      # -module(Name).
      match_module_declaration?(tokens, token_types) ->
        # Find atom after '(' which is the module name
        module_name = extract_atom_value(find_atom_after_token(tokens, :"("))
        symbol = create_symbol(module_name, :module, line, nil, current_module)
        {[symbol | acc], module_name}

      # -record(Name, {Fields}).
      match_record_declaration?(tokens, token_types) ->
        # Find atom after '(' which is the record name
        record_name = extract_atom_value(find_atom_after_token(tokens, :"("))
        symbol = create_symbol(record_name, :type, line, nil, current_module)
        {[symbol | acc], current_module}

      # -type Name() :: ...
      match_type_declaration?(tokens, token_types) ->
        type_name = extract_type_name(tokens)
        symbol = create_symbol(type_name, :type, line, nil, current_module)
        {[symbol | acc], current_module}

      # Function definition: Name(Args) -> ... or Name(Args) when ... ->
      match_function_definition?(token_types) ->
        func_name = extract_function_name(tokens)
        symbol = create_symbol(func_name, :function, line, nil, current_module)
        {[symbol | acc], current_module}

      # -spec Name(Args) -> Ret (just associate with existing function)
      match_spec_declaration?(tokens, token_types) ->
        # Specs are metadata for functions, we don't create separate symbols
        # but we could enhance existing function symbols with spec info
        {acc, current_module}

      true ->
        {acc, current_module}
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern Matching Helpers
  # ---------------------------------------------------------------------------

  defp match_module_declaration?(tokens, types) do
    case types do
      [:-, :atom, :"(", :atom, :")", :dot] ->
        has_keyword_atom?(tokens, :module)

      [:-, :atom, :"(", :atom, :")", :",", :dot] ->
        has_keyword_atom?(tokens, :module)

      _ ->
        # Check for -module pattern with more tokens
        contains_module_attr?(tokens, types)
    end
  end

  defp contains_module_attr?(tokens, types) do
    # Look for pattern: :-, :atom (with value module), :'(', :atom, :')', :dot
    has_dash = :- in types
    has_paren_open = :"(" in types
    has_paren_close = :")" in types
    has_dot = :dot in types
    has_module = has_keyword_atom?(tokens, :module)

    has_dash and has_module and has_paren_open and has_paren_close and has_dot
  end

  defp match_record_declaration?(tokens, types) do
    has_dash = :- in types
    has_paren_open = :"(" in types
    has_curly_open = :"{" in types
    has_record = has_keyword_atom?(tokens, :record)

    has_dash and has_record and has_paren_open and has_curly_open
  end

  defp match_type_declaration?(tokens, types) do
    has_dash = :- in types
    has_paren_open = :"(" in types
    has_type = has_keyword_atom?(tokens, :type)
    has_opaque = has_keyword_atom?(tokens, :opaque)

    has_dash and (has_type or has_opaque) and has_paren_open
  end

  defp match_function_definition?(types) do
    # Function definition pattern: atom, '(', ... , ')', '->'
    # We look for atom followed by '(' and containing '->'
    atom_followed_by_paren?(types) and :-> in types
  end

  defp match_spec_declaration?(tokens, types) do
    has_dash = :- in types
    has_spec = has_keyword_atom?(tokens, :spec)
    has_paren_open = :"(" in types

    has_dash and has_spec and has_paren_open
  end

  defp atom_followed_by_paren?(types) do
    {result, _} =
      Enum.reduce(types, {false, false}, fn type, {found_paren, found_atom} ->
        cond do
          found_paren -> {found_paren, found_atom}
          found_atom and type == :"(" -> {true, true}
          type == :atom -> {found_paren, true}
          true -> {found_paren, found_atom}
        end
      end)

    result
  end

  defp token_type(token) do
    case token do
      {type, _, _} -> type
      {type, _} -> type
      {type, _, _, _} -> type
      _ -> :unknown
    end
  end

  defp extract_atom_value({:atom, _, value}), do: to_string(value)
  defp extract_atom_value({:atom, _, _, value}), do: to_string(value)
  defp extract_atom_value(_), do: nil

  defp atom_token?(token) do
    match?({:atom, _, _}, token) or match?({:atom, _, _, _}, token)
  end

  # Find the atom that appears after a specific token type
  defp find_atom_after_token(tokens, target_type) do
    tokens
    |> Enum.drop_while(fn token -> token_type(token) != target_type end)
    |> Enum.drop(1)
    |> Enum.find(&atom_token?/1)
  end

  # Find the atom after a keyword atom (e.g., after :module, :record, :type)
  defp find_atom_after_keyword(tokens, keyword) do
    tokens
    |> Enum.drop_while(fn token ->
      not (atom_token?(token) and extract_atom_value(token) == to_string(keyword))
    end)
    |> Enum.drop(1)
    |> Enum.find(&atom_token?/1)
  end

  # Helper to check if tokens contain a specific keyword atom (e.g., :record, :type)
  defp has_keyword_atom?(tokens, keyword) do
    Enum.any?(tokens, fn token ->
      atom_token?(token) and extract_atom_value(token) == to_string(keyword)
    end)
  end

  # ---------------------------------------------------------------------------
  # Extract Names
  # ---------------------------------------------------------------------------

  defp extract_type_name(tokens) do
    # For -type name() :: ..., get the atom after -type/-opaque keyword
    # The structure is: -, atom(:type), atom(name), (, ), ::, ...
    case find_atom_after_keyword(tokens, :type) do
      nil ->
        # Try :opaque
        case find_atom_after_keyword(tokens, :opaque) do
          nil -> "unknown_type"
          token -> extract_atom_value(token)
        end

      token ->
        extract_atom_value(token)
    end
  end

  defp extract_function_name(tokens) do
    # Get the first atom token which should be the function name
    # Function pattern: atom(name), '(', ... , ')', '->'
    case Enum.find(tokens, &atom_token?/1) do
      {:atom, _, name} -> to_string(name)
      {:atom, _, _, name} -> to_string(name)
      _ -> "unknown_function"
    end
  end

  # ---------------------------------------------------------------------------
  # Symbol Creation
  # ---------------------------------------------------------------------------

  defp create_symbol(name, kind, line, end_line, _current_module) do
    %{
      name: name,
      kind: kind,
      line: line,
      end_line: end_line,
      doc: nil,
      children: []
    }
  end
end
