defmodule CodePuppyControl.TUI.Syntax do
  @moduledoc """
  Basic ANSI-based syntax highlighting for common languages.

  Uses regex-based tokenization for simplicity — we can enhance later
  with tree-sitter or a proper lexer if needed.

  ## Supported Languages

    * Elixir
    * Python
    * JavaScript / TypeScript
    * Rust
    * Shell / Bash

  ## Usage

      iex> Syntax.highlight("def foo do", "elixir") |> Owl.IO.puts()
  """

  alias Owl.Data

  # ── Colour Palette ────────────────────────────────────────────────────────

  # Semantic token types mapped to Owl.Data sequences
  @token_styles %{
    keyword: :magenta,
    string: :green,
    comment: :faint,
    number: :yellow,
    function: :cyan,
    type: :blue,
    punctuation: :white,
    operator: :magenta,
    atom: :cyan,
    attribute: :yellow,
    variable: :default_color,
    module: :blue,
    decorator: :yellow,
    builtin: :cyan,
    constant: :yellow,
    raw: nil
  }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Highlights code for the given language, returning Owl.Data tagged content.

  Falls back to plain (unstyled) output for unsupported languages.
  """
  @spec highlight(String.t(), String.t()) :: Data.t()
  def highlight(code, language) when is_binary(code) do
    lang = normalize_language(language)

    if config = lang_config(lang) do
      tokenize(code, config)
    else
      code
    end
  end

  # ── Language Normalisation ─────────────────────────────────────────────────

  defp normalize_language("ts"), do: "typescript"
  defp normalize_language("js"), do: "javascript"
  defp normalize_language("sh"), do: "shell"
  defp normalize_language("bash"), do: "shell"
  defp normalize_language("zsh"), do: "shell"
  defp normalize_language(lang), do: String.downcase(lang)

  # ── Language Configs ──────────────────────────────────────────────────────
  #
  # Each config is a map with:
  #   :keywords  — list of keyword strings
  #   :builtins  — list of builtin / standard-lib identifiers
  #   :types     — list of type identifiers
  #   :constants — list of constant identifiers
  #   :comment_single — single-line comment regex (capturing the whole comment)
  #   :comment_multi  — {open, close} for multi-line comments (optional)
  #   :string_delimiters — list of string delimiter patterns (regex)
  #   :attribute_prefix — regex for attributes / decorators (optional)

  defp lang_config("elixir"), do: elixir_config()
  defp lang_config("python"), do: python_config()
  defp lang_config("javascript"), do: js_config()
  defp lang_config("typescript"), do: ts_config()
  defp lang_config("rust"), do: rust_config()
  defp lang_config("shell"), do: shell_config()
  defp lang_config(_), do: nil

  # -- Elixir --

  defp elixir_config do
    %{
      keywords: ~w(
        def defp defmodule defstruct defprotocol defimpl defmacro defmacrop
        defdelegate defexception defguard defguardp
        do end fn if else cond case when with
        for while until receive after send match
        try catch rescue raise throw
        use import require alias quote unquote
        and or not in not
        true false nil
        when
      ),
      builtins: ~w(
        IO Kernel Enum Map Set List String Atom
        Process Agent GenServer Task Supervisor
        Agent DynamicSupervisor Registry
        inspect elem apply put_in get_in update_in
        raise spawn link send receive
        hd tl length is_nil abs div rem
      ),
      types: ~w(),
      constants: ~w(true false nil),
      comment_single: ~r/#.*$/,
      comment_multi: nil,
      string_delimiters: [
        ~r/"""[\s\S]*?"""/,
        ~r/'''[\s\S]*?'''/,
        ~r/"(?:[^"\\]|\\.)*"/,
        ~r/'(?:[^'\\]|\\.)*'/
      ],
      attribute_prefix: ~r/@[a-z_][\w]*!?\??/
    }
  end

  # -- Python --

  defp python_config do
    %{
      keywords: ~w(
        def class if elif else for while with as from import
        try except finally raise return yield pass break continue
        and or not in is lambda global nonlocal assert del
        async await
        True False None
      ),
      builtins: ~w(
        print len range int str float list dict set tuple
        type isinstance issubclass super property
        map filter zip enumerate reversed sorted
        input open file abs max min sum any all
        self cls
      ),
      types: ~w(int float str list dict set tuple bool bytes object complex),
      constants: ~w(True False None),
      comment_single: ~r/#.*$/,
      comment_multi: nil,
      string_delimiters: [
        ~r/"""[\s\S]*?"""/,
        ~r/'''[\s\S]*?'''/,
        ~r/"(?:[^"\\]|\\.)*"/,
        ~r/'(?:[^'\\]|\\.)*'/
      ],
      attribute_prefix: ~r/@[\w.]+/
    }
  end

  # -- JavaScript --

  defp js_config do
    %{
      keywords: ~w(
        const let var function class extends new this super
        if else for while do switch case break continue
        try catch finally throw return yield async await
        import export from default as typeof instanceof of
        in void delete
        true false null undefined
      ),
      builtins: ~w(
        console Math JSON Promise Array Object String Number
        Map Set Date RegExp Error TypeError RangeError
        setTimeout setInterval requestAnimationFrame
        document window process require module exports
      ),
      types: ~w(),
      constants: ~w(true false null undefined NaN Infinity),
      comment_single: ~r{//.*$},
      comment_multi: {"/*", "*/"},
      string_delimiters: [~r/`[\s\S]*?`/, ~r/"(?:[^"\\]|\\.)*"/, ~r/'(?:[^'\\]|\\.)*'/],
      attribute_prefix: nil
    }
  end

  # -- TypeScript (extends JS) --

  defp ts_config do
    js = js_config()

    Map.merge(js, %{
      keywords:
        js.keywords ++
          ~w(type interface enum implements namespace declare abstract readonly override),
      types: ~w(string number boolean void never any unknown object),
      builtins: js.builtins ++ ~w(Partial Required Readonly Record Pick Omit Exclude Extract)
    })
  end

  # -- Rust --

  defp rust_config do
    %{
      keywords: ~w(
        fn let mut const static struct enum impl trait type where
        if else match for while loop break continue return
        use mod pub crate self super as ref move
        unsafe extern async await dyn
        true false
      ),
      builtins: ~w(
        Vec String Box Rc Arc Option Result
        println eprintln format dbg assert assert_eq assert_ne
        clone to_string from into as_ref as_mut
        Some Ok Err None
      ),
      types: ~w(i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 bool char str),
      constants: ~w(true false Some None Ok Err),
      comment_single: ~r{//.*$},
      comment_multi: {"/*", "*/"},
      string_delimiters: [~r/"(?:[^"\\]|\\.)*"/, ~r/b"(?:[^"\\]|\\.)*"/],
      attribute_prefix: ~r/#\[[\s\S]*?\]/
    }
  end

  # -- Shell / Bash --

  defp shell_config do
    %{
      keywords: ~w(
        if then else elif fi case esac for while until do done
        in function select time coproc
      ),
      builtins: ~w(
        echo printf read cd pwd ls mkdir rm cp mv cat grep sed awk
        find sort uniq wc head tail tee xargs
        export source alias unset shift eval exec trap
        true false exit return set local declare typeset readonly
      ),
      types: ~w(),
      constants: ~w(true false),
      comment_single: ~r/#.*$/,
      comment_multi: nil,
      string_delimiters: [~r/"(?:[^"\\]|\\.)*"/, ~r/'[^']*'/],
      attribute_prefix: nil
    }
  end

  # ── Tokenizer ─────────────────────────────────────────────────────────────

  # The tokenizer walks through the source string, matching the highest-
  # priority pattern first (strings > comments > attributes > everything else).
  # Each match produces a tagged fragment; the rest is recursively tokenized.

  @type token :: {pos_integer(), non_neg_integer(), atom(), String.t()}
  # {start, length, type, text}

  @spec tokenize(String.t(), map()) :: Data.t()
  defp tokenize(code, config) do
    # Build ordered list of {regex, type} matchers
    matchers = build_matchers(config)

    # Extract tokens by scanning left-to-right
    tokens = scan_tokens(code, matchers, 0, [])

    # Convert tokens to Owl.Data tagged fragments
    tokens_to_data(tokens, code)
  end

  defp build_matchers(config) do
    matchers = []

    # Strings (highest priority — they can contain anything)
    matchers =
      Enum.reduce(config[:string_delimiters] || [], matchers, fn re, acc ->
        [{re, :string} | acc]
      end)

    # Comments
    matchers =
      if config[:comment_single] do
        [{config.comment_single, :comment} | matchers]
      else
        matchers
      end

    # Attributes / decorators
    matchers =
      if config[:attribute_prefix] do
        [{config.attribute_prefix, :attribute} | matchers]
      else
        matchers
      end

    matchers
  end

  # Scan left-to-right, extracting tokens for strings/comments/attributes.
  # Everything between is tokenized by word-level classification.
  @spec scan_tokens(String.t(), [{Regex.t(), atom()}], pos_integer(), [token()]) :: [token()]
  defp scan_tokens(code, _matchers, pos, acc) when pos >= byte_size(code), do: Enum.reverse(acc)

  defp scan_tokens(code, matchers, pos, acc) do
    remaining = binary_part(code, pos, byte_size(code) - pos)

    case find_first_match(matchers, remaining, pos) do
      nil ->
        # No special tokens found — classify remaining as raw
        if remaining == "" do
          Enum.reverse(acc)
        else
          Enum.reverse([{pos, byte_size(remaining), :raw, remaining} | acc])
        end

      {start_offset, len, type, text} ->
        # Anything before this match is raw
        acc =
          if start_offset > 0 do
            raw = binary_part(remaining, 0, start_offset)
            [{pos, start_offset, :raw, raw} | acc]
          else
            acc
          end

        # Add the matched token
        abs_start = pos + start_offset
        acc = [{abs_start, len, type, text} | acc]

        # Continue after this match
        scan_tokens(code, matchers, abs_start + len, acc)
    end
  end

  defp find_first_match(matchers, remaining, _pos) do
    # Find the earliest match across all matchers
    matchers
    |> Enum.reduce(nil, fn {re, type}, best ->
      case Regex.run(re, remaining, return: :index) do
        [{offset, len}] ->
          candidate = {offset, len, type, binary_part(remaining, offset, len)}
          choose_earlier(best, candidate)

        _ ->
          best
      end
    end)
  end

  defp choose_earlier(nil, candidate), do: candidate

  defp choose_earlier(best, candidate) do
    {best_off, _, _, _} = best
    {cand_off, _, _, _} = candidate

    cond do
      cand_off < best_off ->
        candidate

      cand_off > best_off ->
        best

      # Same position — prefer longer match
      true ->
        {_, best_len, _, _} = best
        {_, cand_len, _, _} = candidate
        if cand_len > best_len, do: candidate, else: best
    end
  end

  # ── Token → Owl.Data Conversion ───────────────────────────────────────────

  defp tokens_to_data(tokens, _code) do
    tokens
    |> Enum.map(fn {_start, _len, type, text} ->
      classify_and_tag(text, type)
    end)
    |> Enum.map(&word_level_tag/1)
    |> List.flatten()
  end

  # Already-classified tokens (strings, comments, attributes)
  defp classify_and_tag(text, :string), do: tag_token(text, :string)
  defp classify_and_tag(text, :comment), do: tag_token(text, :comment)
  defp classify_and_tag(text, :attribute), do: tag_token(text, :attribute)

  # Raw text needs word-level classification
  defp classify_and_tag(text, :raw), do: {:raw, text}

  defp tag_token(text, type) do
    style = Map.get(@token_styles, type, :default_color)
    if style, do: Data.tag(text, style), else: text
  end

  # Take a {:raw, text} and classify individual words
  defp word_level_tag({:raw, text}) do
    # Split into word/non-word segments to classify identifiers
    parts =
      Regex.split(~r{(\b\w[\w!?]*\b)}, text, include_captures: true, trim: true)

    Enum.map(parts, fn part ->
      cond do
        # Numbers
        Regex.match?(~r/^\d+(\.\d+)?$/, part) ->
          tag_token(part, :number)

        # Identifier-like — check keyword/builtin/type/constant
        Regex.match?(~r/^\w[\w!?]*$/, part) ->
          classify_identifier(part)

        # Punctuation / operators / whitespace — pass through
        true ->
          part
      end
    end)
  end

  # A small generic keyword set for cross-language common keywords
  # (language-specific keywords are handled by the matchers above)
  @generic_keywords MapSet.new(~w(
    def class if else for while return import export from
    try catch finally throw new function const let var
    true false nil null undefined
  ))

  # Already-tagged token passes through
  defp word_level_tag(already_tagged), do: already_tagged

  defp classify_identifier(word) do
    # This is called without a config reference — we do a simple heuristic:
    # Check against a generic keyword set. For language-specific classification,
    # the string/comment/attribute matchers handle most of the important stuff.
    cond do
      word in @generic_keywords -> tag_token(word, :keyword)
      true -> word
    end
  end

  # ── Convenience: Highlight with Language Detection ────────────────────────

  @doc """
  Highlights code, detecting the language from a filename extension.

      iex> Syntax.highlight_file("def foo, do: bar", "foo.ex")
  """
  @spec highlight_file(String.t(), String.t()) :: Data.t()
  def highlight_file(code, filename) do
    ext = Path.extname(filename) |> String.trim_leading(".")
    lang = ext_to_lang(ext)
    highlight(code, lang)
  end

  defp ext_to_lang("ex"), do: "elixir"
  defp ext_to_lang("exs"), do: "elixir"
  defp ext_to_lang("py"), do: "python"
  defp ext_to_lang("js"), do: "javascript"
  defp ext_to_lang("ts"), do: "typescript"
  defp ext_to_lang("tsx"), do: "typescript"
  defp ext_to_lang("jsx"), do: "javascript"
  defp ext_to_lang("rs"), do: "rust"
  defp ext_to_lang("sh"), do: "shell"
  defp ext_to_lang("bash"), do: "shell"
  defp ext_to_lang("zsh"), do: "shell"
  defp ext_to_lang(_), do: "text"
end
