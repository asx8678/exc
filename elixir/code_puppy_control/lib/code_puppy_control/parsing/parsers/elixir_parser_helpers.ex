defmodule CodePuppyControl.Parsing.Parsers.ElixirParserHelpers do
  @moduledoc false

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  # Type definitions like `@type foo :: bar` have AST: {:::, _, [{:foo, _, nil}, {:bar, _, nil}]}
  # We need to extract the left side as the type name
  def extract_type_name({:"::", _, [left, _right]}), do: extract_type_name(left)
  def extract_type_name({type_name, meta, _}) when is_atom(type_name), do: {type_name, meta, nil}
  def extract_type_name(other), do: {other, [], nil}

  def extract_spec_name({:when, _, [inner, _guard]}), do: extract_spec_name(inner)

  def extract_spec_name({func_name, _, _}) when is_atom(func_name) do
    to_string(func_name)
  end

  def extract_spec_name(other), do: inspect(other)

  def extract_callback_name({func_name, _, _}) when is_atom(func_name) do
    to_string(func_name)
  end

  def extract_callback_name(other), do: inspect(other)

  def extract_doc_string(string) when is_binary(string), do: String.trim(string)
  def extract_doc_string({:<<>>, _, parts}), do: extract_heredoc(parts)
  def extract_doc_string(_), do: nil

  def extract_heredoc(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      bin when is_binary(bin) -> bin
      {:\\, _, [bin, _]} when is_binary(bin) -> bin
      _ -> ""
    end)
    |> Enum.join()
    |> String.trim()
  end

  def extract_heredoc(_), do: nil

  def format_error_message({line, message, _}) when is_integer(line) do
    "Line #{line}: #{message}"
  end

  def format_error_message(message) when is_binary(message) do
    message
  end

  def format_error_message(other) do
    inspect(other)
  end

  def extract_error_line({line, _, _}) when is_integer(line), do: line
  def extract_error_line(_), do: 1
end
