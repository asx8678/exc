defmodule CodePuppyControl.Parsing.Parsers.TsxParser do
  @moduledoc """
  TSX parser extending TypeScript with JSX support.

  This parser removes JSX, return statements, and simplifies declaration bodies 
  before delegating to the TypeScript parser.
  """

  @behaviour CodePuppyControl.Parsing.ParserBehaviour

  alias CodePuppyControl.Parsing.Parsers.TypeScriptParser
  alias CodePuppyControl.Parsing.ParserRegistry

  @impl true
  def language, do: "tsx"

  @impl true
  def file_extensions, do: [".tsx"]

  @impl true
  def supported?, do: true

  @impl true
  def parse(source) when is_binary(source) do
    stripped = simplify_tsx(source)

    case TypeScriptParser.parse(stripped) do
      {:ok, result} ->
        {:ok, %{result | language: "tsx"}}

      error ->
        error
    end
  end

  def register do
    ParserRegistry.register(__MODULE__)
  end

  # Simplify TSX by removing JSX, return statements, and simplifying bodies
  defp simplify_tsx(source) do
    source
    |> remove_jsx()
    |> remove_return_statements()
    |> simplify_dotted_extends()
    |> simplify_declaration_bodies()
  end

  defp remove_jsx(source) do
    result = Regex.replace(~r/<[^>]+\/>/, source, "null")
    replace_paired_jsx(result)
  end

  defp replace_paired_jsx(source) do
    result = Regex.replace(~r/<[^>]+>[^<]*<\/[^>]+>/, source, "null")

    if result != source do
      replace_paired_jsx(result)
    else
      source
    end
  end

  defp remove_return_statements(source) do
    Regex.replace(~r/return\s+[^;]+;/, source, "")
  end

  defp simplify_dotted_extends(source) do
    Regex.replace(
      ~r/extends\s+([a-zA-Z][a-zA-Z0-9]*)\.[a-zA-Z][a-zA-Z0-9]*/,
      source,
      "extends \\1"
    )
  end

  # Simplify declaration bodies { ... } to empty { }
  # This handles interface, class, enum, type bodies that confuse the TypeScript parser
  defp simplify_declaration_bodies(source) do
    # Match { followed by content until }, but not { } itself
    # Be careful not to match empty braces
    Regex.replace(~r/\{[^{}]+\}/, source, "{ }")
  end
end
