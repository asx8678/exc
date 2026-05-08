defmodule CodePuppyControl.Text.ContentPrep do
  @moduledoc """
  Content preparation: unified text detection, EOL normalization, and BOM stripping.

  Port of `code_puppy_core/src/content_prep.rs`.

  Provides a single-pass `prepare_content/1` function that:
  - Detects and strips UTF-8 BOM
  - Detects NUL bytes (binary indicator)
  - Detects CRLF sequences
  - If text: normalizes CRLF to LF

  Returns a `ContentPrepResult` struct with all detection metadata.

  ## Examples

      iex> ContentPrep.prepare_content("hello world\\r\\n")
      %ContentPrepResult{content: "hello world\\n", is_text: true, had_bom: false, had_crlf: true}

      iex> ContentPrep.prepare_content(<<0xEF, 0xBB, 0xBF, "file\\r\\ncontent">>)
      %ContentPrepResult{content: "file\\ncontent", is_text: true, had_bom: true, had_crlf: true}

      iex> ContentPrep.prepare_content(<<0x00, 0x01, 0x02>>)
      %ContentPrepResult{content: <<0x00, 0x01, 0x02>>, is_text: false, had_bom: false, had_crlf: false}
  """

  alias CodePuppyControl.Text.EOL

  # UTF-8 BOM bytes: EF BB BF
  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @enforce_keys [:content, :is_text, :had_bom, :had_crlf]

  defstruct [
    :content,
    :is_text,
    :had_bom,
    :had_crlf,
    :original_bom
  ]

  @typedoc """
  Result of preparing content.

  - `content` — The processed content (BOM stripped, CRLF normalized if text)
  - `is_text` — True if content appears to be text (no NUL, valid UTF-8, 90%+ printable)
  - `had_bom` — True if a UTF-8 BOM was present and stripped
  - `had_crlf` — True if CRLF sequences were detected (and normalized if is_text)
  - `original_bom` — The BOM bytes if present, nil otherwise (for restoration)
  """
  @type t :: %__MODULE__{
          content: binary(),
          is_text: boolean(),
          had_bom: boolean(),
          had_crlf: boolean(),
          original_bom: binary() | nil
        }

  @doc """
  Prepare content with full metadata detection.

  Performs a single-pass through content to:
  1. Detect and strip UTF-8 BOM
  2. Detect NUL bytes (binary check)
  3. Detect CRLF sequences
  4. If text: normalize CRLF → LF and orphan CR → LF

  Returns a `ContentPrepResult` struct with the processed content and metadata.

  ## Options

  - `:normalize` — Whether to normalize line endings (default: `true`)
  - `:strip_bom` — Whether to strip BOM (default: `true`)

  ## Examples

      iex> ContentPrep.prepare_content("hello\\r\\nworld")
      %ContentPrepResult{content: "hello\\nworld", is_text: true, had_bom: false, had_crlf: true, original_bom: nil}

      iex> ContentPrep.prepare_content("plain text")
      %ContentPrepResult{content: "plain text", is_text: true, had_bom: false, had_crlf: false, original_bom: nil}

      iex> ContentPrep.prepare_content(<<0x00, "nul">>)
      %ContentPrepResult{content: <<0x00, "nul">>, is_text: false, had_bom: false, had_crlf: false, original_bom: nil}
  """
  @spec prepare_content(binary(), keyword()) :: t()
  def prepare_content(raw, opts \\ [])
  def prepare_content("", _opts), do: return_empty_result()

  def prepare_content(raw, opts) when is_binary(raw) do
    normalize = Keyword.get(opts, :normalize, true)
    strip_bom = Keyword.get(opts, :strip_bom, true)

    # Strip BOM first if present (and requested)
    {content_bytes, had_bom, original_bom} =
      if strip_bom do
        case raw do
          <<@utf8_bom, rest::binary>> -> {rest, true, @utf8_bom}
          _ -> {raw, false, nil}
        end
      else
        {raw, false, nil}
      end

    # Check for NUL bytes (binary detection)
    has_nul = :binary.match(content_bytes, <<0>>) != :nomatch

    # Check for CRLF sequences
    has_crlf = :binary.match(content_bytes, "\r\n") != :nomatch

    # If NUL found, it's binary - return as-is
    if has_nul do
      %__MODULE__{
        content: content_bytes,
        is_text: false,
        had_bom: had_bom,
        had_crlf: has_crlf,
        original_bom: original_bom
      }
    else
      # It's text - check printable ratio for extra safety
      is_text = EOL.looks_textish(content_bytes)

      if !is_text do
        # Binary-like but no NUL - still treat as binary
        %__MODULE__{
          content: content_bytes,
          is_text: false,
          had_bom: had_bom,
          had_crlf: has_crlf,
          original_bom: original_bom
        }
      else
        # It's confirmed text - normalize line endings if requested
        content =
          if normalize do
            EOL.normalize_eol(content_bytes)
          else
            content_bytes
          end

        %__MODULE__{
          content: content,
          is_text: true,
          had_bom: had_bom,
          had_crlf: has_crlf,
          original_bom: original_bom
        }
      end
    end
  end

  @doc """
  Check if content appears to be human-readable text.

  Wrapper around `Text.EOL.looks_textish/1` for convenience.

  ## Examples

      iex> ContentPrep.looks_textish("hello world")
      true

      iex> ContentPrep.looks_textish(<<0x00, 0x01>>)
      false
  """
  @spec looks_textish(binary()) :: boolean()
  def looks_textish(raw) when is_binary(raw) do
    EOL.looks_textish(raw)
  end

  @doc """
  Normalize CRLF to LF in text content.

  Only normalizes if content looks like text. Binary content is returned unchanged.

  ## Examples

      iex> ContentPrep.normalize_eol("line1\\r\\nline2")
      "line1\\nline2"

      iex> ContentPrep.normalize_eol(<<0x00, 0x01>>)
      <<0x00, 0x01>>
  """
  @spec normalize_eol(binary()) :: binary()
  def normalize_eol(content) when is_binary(content) do
    EOL.normalize_eol(content)
  end

  @doc """
  Strip UTF-8 BOM from beginning of content if present.

  Returns a tuple of `{content_without_bom, had_bom, original_bom}`.

  ## Examples

      iex> ContentPrep.strip_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      {"hello", true, <<0xEF, 0xBB, 0xBF>>}

      iex> ContentPrep.strip_bom("hello")
      {"hello", false, nil}
  """
  @spec strip_bom(binary()) :: {binary(), boolean(), binary() | nil}
  def strip_bom(<<@utf8_bom, rest::binary>>), do: {rest, true, @utf8_bom}
  def strip_bom(content) when is_binary(content), do: {content, false, nil}

  @doc """
  Restore BOM to content if one was originally present.

  ## Examples

      iex> ContentPrep.restore_bom("content", <<0xEF, 0xBB, 0xBF>>)
      <<0xEF, 0xBB, 0xBF, "content">>

      iex> ContentPrep.restore_bom("content", nil)
      "content"
  """
  @spec restore_bom(binary(), binary() | nil) :: binary()
  def restore_bom(content, nil) when is_binary(content), do: content
  def restore_bom(content, bom) when is_binary(content) and is_binary(bom), do: bom <> content

  # Private functions

  defp return_empty_result do
    %__MODULE__{
      content: "",
      is_text: true,
      had_bom: false,
      had_crlf: false,
      original_bom: nil
    }
  end
end
