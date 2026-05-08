defmodule CodePuppyControl.SessionStorage.Format do
  @moduledoc """
  Session file format constants and serialization helpers.

  ## Formats handled

  | Format | Magic | Description |
  |--------|-------|-------------|
  | `code-puppy-ex-v1` | N/A | Current Elixir-native JSON format |
  | `pydantic-ai-json-v2` | N/A | Python subagent sessions (`.msgpack` ext, actually JSON) |
  | `JSONV\\x01\\x00\\x00` | `JSONV\\x01\\x00\\x00` | Python autosaves (`.pkl` ext, JSON+HMAC) |
  | `MSGPACK\\x01` | `MSGPACK\\x01` | Legacy Python msgpack sessions |

  The Elixir port writes exclusively to `~/.code_puppy_ex/sessions/` and never
  touches `~/.code_puppy/` (isolation requirement from ).
  """

  # --- Current format identifier ---
  @current_format "code-puppy-ex-v1"

  # --- File extensions ---
  @session_ext ".json"
  @metadata_suffix "_meta.json"

  # --- Python format magic bytes ---
  @json_magic "JSONV\x01\x00\x00"
  @msgpack_magic "MSGPACK\x01"

  @doc "Returns the current session format identifier."
  @spec current_format :: String.t()
  def current_format, do: @current_format

  @doc "Returns the session file extension."
  @spec session_ext :: String.t()
  def session_ext, do: @session_ext

  @doc "Returns the metadata file suffix."
  @spec metadata_suffix :: String.t()
  def metadata_suffix, do: @metadata_suffix

  @doc "Returns the JSONV magic header bytes."
  @spec json_magic :: binary()
  def json_magic, do: @json_magic

  @doc "Returns the MSGPACK magic header bytes."
  @spec msgpack_magic :: binary()
  def msgpack_magic, do: @msgpack_magic

  @doc """
  Detects the format of raw session file bytes.

  ## Returns

    * `:elixir_json` - Current Elixir-native JSON format
    * `:python_json_hmac` - Python JSONV+HMAC format (`.pkl` files)
    * `:python_msgpack_hmac` - Python MSGPACK+HMAC format
    * `:python_plain_json` - Python pydantic-ai JSON format (`.msgpack` extension)
    * `:unknown` - Unrecognized format
  """
  @spec detect_format(binary()) ::
          :elixir_json
          | :python_json_hmac
          | :python_msgpack_hmac
          | :python_plain_json
          | :unknown
  def detect_format(<<@json_magic, _rest::binary>>), do: :python_json_hmac
  def detect_format(<<@msgpack_magic, _rest::binary>>), do: :python_msgpack_hmac

  def detect_format(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"format" => "pydantic-ai-json-v2"}} ->
        :python_plain_json

      {:ok, %{"format" => @current_format}} ->
        :elixir_json

      {:ok, %{"format" => _other}} ->
        :unknown

      {:ok, _} ->
        :unknown

      {:error, _} ->
        :unknown
    end
  end

  def detect_format(_), do: :unknown

  @doc """
  Parses a Python JSONV+HMAC session file.

  Skips the 8-byte magic header and 32-byte HMAC, then decodes the JSON payload.
  Does NOT verify HMAC (the Elixir port doesn't share the Python HMAC key).

  ## Returns

    * `{:ok, map()}` - Decoded session data
    * `{:error, reason}` - On parse failure
  """
  @spec parse_python_json_hmac(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse_python_json_hmac(<<@json_magic, _hmac::binary-size(32), json_bytes::binary>>) do
    case Jason.decode(json_bytes) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, other} -> {:error, "Expected map, got #{inspect(other)}"}
      {:error, reason} -> {:error, "JSON decode error: #{inspect(reason)}"}
    end
  end

  def parse_python_json_hmac(_), do: {:error, "Invalid JSONV+HMAC format"}

  @doc """
  Normalizes a session name to a safe filename stem.

  Replaces characters that are unsafe in filenames with hyphens,
  then collapses runs of hyphens. Falls back to "session" if empty.
  """
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> fallback_empty("session")
  end

  defp fallback_empty("", fallback), do: fallback
  defp fallback_empty(name, _fallback), do: name

  @doc """
  Builds session file paths for the given base directory and name.

  Returns a map with `:session_path` and `:metadata_path` keys.
  """
  @spec build_paths(Path.t(), String.t()) :: %{session_path: Path.t(), metadata_path: Path.t()}
  def build_paths(base_dir, name) do
    stem = normalize_name(name)

    %{
      session_path: Path.join(base_dir, "#{stem}#{@session_ext}"),
      metadata_path: Path.join(base_dir, "#{stem}#{@metadata_suffix}")
    }
  end
end
