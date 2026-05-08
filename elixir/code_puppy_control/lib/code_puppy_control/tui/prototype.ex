defmodule CodePuppyControl.TUI.Prototype do
  @moduledoc """
  TUI prototype for Go/No-Go gate.

  Run: mix run -e "CodePuppyControl.TUI.Prototype.demo()"

  Proves four capabilities with zero dependencies beyond stdlib:
    1. Streaming text (character-by-character, simulating LLM tokens)
    2. Syntax highlighting via raw ANSI codes
    3. Modal question prompt
    4. Readline-style input
  """

  # ANSI helpers
  defp reset, do: "\e[0m"
  defp bold, do: "\e[1m"
  defp dim, do: "\e[2m"
  defp cyan, do: "\e[36m"
  defp green, do: "\e[32m"
  defp yellow, do: "\e[33m"
  defp magenta, do: "\e[35m"
  defp blue, do: "\e[34m"
  defp white, do: "\e[37m"
  defp bg_cyan, do: "\e[46m"

  defp clear_screen, do: IO.write("\e[2J\e[H")

  @spec demo() :: :ok
  def demo do
    clear_screen()

    # Banner
    IO.write("\n #{bg_cyan()}#{bold()}#{white()} Code Puppy TUI Prototype #{reset()}\n")
    IO.write(" #{dim()}Go/No-Go Gate#{reset()}\n\n")

    # 1 - Streaming text
    IO.write(" #{bold()}#{cyan()}1. STREAMING#{reset()}\n\n")

    stream(
      "Hello, Code Puppy! This text arrives token by token, just like a real LLM response. Watch it flow in progressively.\n\n"
    )

    # 2 - Syntax highlighting
    IO.write(" #{bold()}#{magenta()}2. SYNTAX HIGHLIGHTING#{reset()}\n\n")
    highlight_elixir()
    IO.write("\n")

    # 3 - Modal + 4 - Input
    IO.write(" #{bold()}#{yellow()}3. MODAL + INPUT#{reset()}\n\n")
    modal()
    answer = IO.gets(" #{cyan()}>> #{reset()}") |> maybe_trim()
    IO.write("\n #{green()}You said: #{bold()}#{answer}#{reset()}\n")

    IO.write("\n #{dim()}Prototype complete.#{reset()}\n")
    :ok
  end

  # -- 1. Streaming --------------------------------------------------------

  defp stream(text) do
    text
    |> String.graphemes()
    |> Enum.each(fn ch ->
      IO.write(ch)
      Process.sleep(15)
    end)
  end

  # -- 2. Syntax highlighting ---------------------------------------------

  @elixir_keywords MapSet.new(
                     ~w(def defp defmodule do end fn if else case with use import require alias when true false nil)
                   )
  @elixir_builtins MapSet.new(~w(IO Kernel Enum Map String Atom Process GenServer Task))

  defp highlight_elixir do
    lines = [
      "defmodule Puppy do",
      " def fetch(url) do",
      " case IO.read(url) do",
      " {:ok, data} -> {:ok, data}",
      " {:error, _} -> {:error, :not_found}",
      " end",
      " end",
      "end"
    ]

    IO.write(" #{dim()}+ elixir#{reset()}\n")

    Enum.each(lines, fn line ->
      colored = colorize_line(line)
      IO.write(" #{dim()}|#{reset()} #{colored}\n")
    end)
  end

  defp colorize_line(line) do
    line
    |> String.split(~r{(\b\w+\b)}, include_captures: true)
    |> Enum.map(fn token ->
      cond do
        token in @elixir_keywords -> "#{magenta()}#{token}#{reset()}"
        token in @elixir_builtins -> "#{cyan()}#{token}#{reset()}"
        String.starts_with?(token, ":") -> "#{blue()}#{token}#{reset()}"
        String.starts_with?(token, "#") -> "#{dim()}#{token}#{reset()}"
        true -> token
      end
    end)
    |> Enum.join()
  end

  # -- 3. Modal -----------------------------------------------------------

  defp modal do
    IO.write(" +--------------------------------------+\n")
    IO.write(" | #{bold()}What should the puppy do?#{reset()} |\n")
    IO.write(" | |\n")
    IO.write(" | #{cyan()}1#{reset()} Fetch a file |\n")
    IO.write(" | #{cyan()}2#{reset()} Run a command |\n")
    IO.write(" | #{cyan()}q#{reset()} Quit |\n")
    IO.write(" +--------------------------------------+\n")
  end

  defp maybe_trim(:eof), do: "(eof)"
  defp maybe_trim({:error, _}), do: "(error)"
  defp maybe_trim(s), do: String.trim(s)
end
