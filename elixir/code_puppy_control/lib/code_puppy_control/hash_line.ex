defmodule CodePuppyControl.HashLine do
  @moduledoc """
  Pure Elixir implementation of per-line content hashing for file edit anchoring.

  This module replaces `CodePuppyControl.HashlineNif` (the Rust NIF) with a
  drop-in pure Elixir implementation using the `:xxhash` library.

  Each line gets a 2-character anchor encoded via `NIBBLE_STR`
  ("ZPMQVRWSNKTXJBYH") so the LLM can reference lines precisely.

  Compatible with oh-my-pi's hashline format and the Python/Rust
  reference implementations in code_puppy_core.

  ## Algorithm

  For each line:
  1. Strip trailing whitespace and `\\r`
  2. Check if line has any alphanumeric Unicode character
  3. Use seed = 0 if has alphanumeric, else seed = line index
  4. Compute xxHash32 with the seed
  5. Take lowest byte of hash
  6. Encode via NIBBLE_STR: high nibble -> first char, low nibble -> second char

  ## Format

  `format_hashlines/2` produces lines like: `1#AB:original content`

  Where `1` is the line number, `AB` is the 2-char hash anchor,
  and everything after the colon is the original line content.
  """

  # NIBBLE_STR encoding: 16 characters for hex nibble values 0-15
  @nibble_str "ZPMQVRWSNKTXJBYH"

  # xxhash32 constants for empty-input computation
  # Source: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
  # NOTE: PRIME32_2 was previously incorrect (2_246_682_519 instead of 2_246_822_519)
  # This caused parity failures with the Rust NIF for empty/whitespace lines.
  @prime_32_2 2_246_822_519
  @prime_32_3 3_266_489_917
  @prime_32_5 374_761_393
  @mask_32 0xFFFFFFFF

  @doc """
  Compute a 2-character hash anchor for a single line.

  ## Algorithm

  1. Strips trailing whitespace and `\\r` from the line
  2. Checks if cleaned line has any alphanumeric Unicode character
  3. Uses seed = 0 if has alphanumeric, else seed = line index
  4. Computes xxHash32 with the seed
  5. Takes lowest byte and encodes via NIBBLE_STR

  ## Examples

      iex> CodePuppyControl.HashLine.compute_line_hash(1, "hello world")
      "MM"

      iex> CodePuppyControl.HashLine.compute_line_hash(1, "   ")
      "ZB"

      iex> CodePuppyControl.HashLine.compute_line_hash(1, "foo") == 
      ...>   CodePuppyControl.HashLine.compute_line_hash(99, "foo")
      # true - alphanumeric content ignores idx (seed=0)

  ## Parameters

  - `idx` - Line index (0-based or 1-based, used as seed for whitespace-only lines)
  - `line` - The line content to hash

  ## Returns

  A 2-character uppercase string from NIBBLE_STR characters.
  """
  @spec compute_line_hash(non_neg_integer(), String.t()) :: String.t()
  def compute_line_hash(idx, line) when is_integer(idx) and idx >= 0 and is_binary(line) do
    # Step 1: Strip trailing whitespace and \r
    cleaned =
      line
      |> String.trim_trailing()
      |> String.trim_trailing("\r")

    # Step 2: Check if cleaned has any alphanumeric Unicode char
    has_alnum = alphanumeric?(cleaned)

    # Step 3: seed = 0 if has_alnum, else idx
    seed = if has_alnum, do: 0, else: idx

    # Step 4: Compute xxHash32
    # The xxhash library hardcodes empty input to a constant, ignoring seed.
    # For whitespace-only lines where seed matters, we must compute correctly.
    byte_size = byte_size(cleaned)

    hash =
      if byte_size == 0 do
        # Empty input: apply xxhash32 finalization directly with seed
        # acc = seed + PRIME_32_5, then add length (0), then finalization rounds
        acc = Bitwise.band(seed + @prime_32_5, @mask_32)
        xxh32_finalize(acc, 0)
      else
        XXHash.xxh32(cleaned, byte_size, seed)
      end

    # Step 5: Take lowest byte (hash &&& 0xFF)
    byte = Bitwise.band(hash, 0xFF)

    # Step 6: Encode via NIBBLE_STR
    hi_nibble = Bitwise.band(Bitwise.bsr(byte, 4), 0xF)
    lo_nibble = Bitwise.band(byte, 0xF)

    hi = :binary.at(@nibble_str, hi_nibble)
    lo = :binary.at(@nibble_str, lo_nibble)

    <<hi, lo>>
  end

  @doc """
  Format text with hashline prefixes.

  Each line becomes `LINE_NUM#HASH:original_line`.

  ## Examples

      iex> CodePuppyControl.HashLine.format_hashlines("foo\\nbar", 1)
      "1#XX:foo\\n2#YY:bar"

  ## Parameters

  - `text` - The text to format (split on `\\n`)
  - `start_line` - The starting line number (1-based by convention)

  ## Returns

  Formatted text with each line prefixed by its number, hash anchor, and colon.
  """
  @spec format_hashlines(String.t(), non_neg_integer()) :: String.t()
  def format_hashlines(text, start_line)
      when is_binary(text) and is_integer(start_line) and start_line >= 0 do
    lines = String.split(text, "\n")

    lines
    |> Enum.with_index(start_line)
    |> Enum.map(fn {line, idx} ->
      hash = compute_line_hash(idx, line)
      "#{idx}##{hash}:#{line}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Strip hashline prefixes from text, returning plain content.

  Lines matching the pattern `^\\d+#[A-Z]{2}:` have the prefix removed.
  Other lines pass through unchanged.

  The prefix format is: `DIGITS#UPPER_UPPER:` where:
  - Before `#`: one or more digits (line number)
  - After `#`: exactly 2 uppercase ASCII letters (hash anchor)
  - After the letters: a colon

  ## Examples

      iex> CodePuppyControl.HashLine.strip_hashline_prefixes("1#AB:hello")
      "hello"
      
      iex> CodePuppyControl.HashLine.strip_hashline_prefixes("plain text")
      "plain text"  # unchanged
      
      iex> CodePuppyControl.HashLine.strip_hashline_prefixes("1#AB:hello\\n2#CD:world")
      "hello\\nworld"

  ## Parameters

  - `text` - Text potentially containing hashline prefixes

  ## Returns

  Text with hashline prefixes stripped from matching lines.
  """
  @spec strip_hashline_prefixes(String.t()) :: String.t()
  def strip_hashline_prefixes(text) when is_binary(text) do
    lines = String.split(text, "\n")

    stripped_lines = Enum.map(lines, &strip_one_hashline_prefix/1)

    Enum.join(stripped_lines, "\n")
  end

  @doc """
  Validate that a stored hash anchor still matches the current line content.

  Returns `true` if `compute_line_hash(idx, line)` equals `expected_hash`.

  ## Examples

      iex> hash = CodePuppyControl.HashLine.compute_line_hash(5, "some code")
      iex> CodePuppyControl.HashLine.validate_hashline_anchor(5, "some code", hash)
      true
      
      iex> CodePuppyControl.HashLine.validate_hashline_anchor(5, "different code", hash)
      false

  ## Parameters

  - `idx` - Line index
  - `line` - Current line content
  - `expected_hash` - The expected 2-character hash anchor

  ## Returns

  `true` if the computed hash matches expected, `false` otherwise.
  """
  @spec validate_hashline_anchor(non_neg_integer(), String.t(), String.t()) :: boolean()
  def validate_hashline_anchor(idx, line, expected_hash)
      when is_integer(idx) and idx >= 0 and is_binary(line) and is_binary(expected_hash) do
    compute_line_hash(idx, line) == expected_hash
  end

  # -----------------------------------------------------------------------------
  # Private Functions
  # -----------------------------------------------------------------------------

  # Checks if string contains any alphanumeric Unicode character.
  # Uses Unicode property \p{L} (letter) and \p{N} (number).
  defp alphanumeric?(""), do: false

  defp alphanumeric?(string) when is_binary(string) do
    # Use regex to check for any alphanumeric character
    # \p{L} = any Unicode letter, \p{N} = any Unicode number
    Regex.match?(~r/[\p{L}\p{N}]/u, string)
  end

  # Strip a single hashline prefix from a line if present.
  # Pattern: DIGITS#UPPER_UPPER:rest
  # Returns the line unchanged if no valid prefix found.
  defp strip_one_hashline_prefix(line) when is_binary(line) do
    case Regex.run(~r/^([0-9]+)#([A-Z]{2}):(.*)$/, line) do
      [_, _digits, _hash, rest] -> rest
      _ -> line
    end
  end

  # xxhash32 finalization rounds (when input is empty or processed separately)
  # Based on xxhash reference implementation
  defp xxh32_finalize(acc, length) do
    acc
    |> then(fn a -> Bitwise.band(a + length, @mask_32) end)
    |> then(fn a -> Bitwise.bxor(a, Bitwise.bsr(a, 15)) end)
    |> then(fn a -> Bitwise.band(a * @prime_32_2, @mask_32) end)
    |> then(fn a -> Bitwise.bxor(a, Bitwise.bsr(a, 13)) end)
    |> then(fn a -> Bitwise.band(a * @prime_32_3, @mask_32) end)
    |> then(fn a -> Bitwise.bxor(a, Bitwise.bsr(a, 16)) end)
  end
end
