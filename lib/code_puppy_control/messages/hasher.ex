defmodule CodePuppyControl.Messages.Hasher do
  @moduledoc """
  Port of `code_puppy_core/src/message_hashing.rs`.

  Fast message hashing using `:erlang.phash2/1` (Erlang's portable hash function).
  This replaces the Rust FxHash implementation for Elixir-native message processing.

  Hash values are consistent within a single session but do NOT need to match
  Rust FxHash values - they are only compared within the same Elixir process.

  ## Algorithm

  1. `stringify_part_for_hash/1` - builds canonical string representation of a part:
     `"part_kind|tool_call_id=X|tool_name=Y|content=Z"` (attributes joined by `|`)

  2. `hash_message/1` - builds header bits (role, instructions), combines with all
     part strings, joins with `||`, then hashes with `:erlang.phash2/1`

  ## Usage

      alias CodePuppyControl.Messages.Hasher

      message = %{
        kind: "request",
        role: "user",
        instructions: nil,
        parts: [%{part_kind: "text", content: "hello", content_json: nil,
                  tool_call_id: nil, tool_name: nil, args: nil}]
      }

      hash = Hasher.hash_message(message)
  """

  alias CodePuppyControl.Messages.Types

  @doc """
  Compute a stable hash for a message.

  Builds a canonical string from header bits (role, instructions) plus all
  part strings, then hashes using `:erlang.phash2/1`.

  ## Parameters

    * `msg` - A message map conforming to `Types.message()`

  ## Returns

    * `integer()` - A positive hash value

  ## Examples

      iex> msg = %{kind: "request", role: "user", instructions: nil, parts: []}
      iex> hash = Hasher.hash_message(msg)
      iex> is_integer(hash) and hash >= 0
      true
  """
  @spec hash_message(Types.message()) :: integer()
  def hash_message(msg) do
    header_bits = build_header_bits(msg)
    part_strings = Enum.map(field(msg, :parts) || [], &stringify_part_for_hash/1)

    canonical =
      header_bits
      |> Enum.concat(part_strings)
      |> Enum.join("||")

    :erlang.phash2(canonical)
  end

  @doc """
  Build the canonical string for a part (for hashing).

  Mirrors the Python `BaseAgent._stringify_part()` method.
  Format: `"part_kind|tool_call_id=X|tool_name=Y|content=Z"`

  ## Parameters

    * `part` - A message part map conforming to `Types.message_part()`

  ## Returns

    * `String.t()` - Canonical string representation
  """
  @spec stringify_part_for_hash(Types.message_part()) :: String.t()
  def stringify_part_for_hash(part) do
    part_kind = field(part, :part_kind)
    tool_call_id = field(part, :tool_call_id)
    tool_name = field(part, :tool_name)
    content = field(part, :content)
    content_json = field(part, :content_json)

    attributes = [part_kind]

    attributes =
      if nonempty_string(tool_call_id) do
        attributes ++ ["tool_call_id=#{tool_call_id}"]
      else
        attributes
      end

    attributes =
      if nonempty_string(tool_name) do
        attributes ++ ["tool_name=#{tool_name}"]
      else
        attributes
      end

    attributes =
      cond do
        # Rust: if let Some(ref content) = part.content (empty string is Some(""))
        content != nil ->
          attributes ++ ["content=#{content}"]

        nonempty_string(content_json) ->
          attributes ++ ["content=#{content_json}"]

        true ->
          attributes ++ ["content=None"]
      end

    Enum.join(attributes, "|")
  end

  # Private functions

  @spec build_header_bits(Types.message()) :: [String.t()]
  defp build_header_bits(msg) do
    role = field(msg, :role)
    instructions = field(msg, :instructions)

    bits = []

    bits =
      if nonempty_string(role) do
        ["role=#{role}" | bits]
      else
        bits
      end

    bits =
      if nonempty_string(instructions) do
        ["instructions=#{instructions}" | bits]
      else
        bits
      end

    # Reverse to maintain expected order (role before instructions)
    Enum.reverse(bits)
  end

  @spec nonempty_string(String.t() | nil) :: boolean()
  defp nonempty_string(nil), do: false
  defp nonempty_string(""), do: false
  defp nonempty_string(_), do: true

  # Access a field from a map that may use atom or string keys.
  # This allows cross-module compatibility when data comes from JSON (string keys)
  # or from Elixir code (atom keys).
  @doc false
  defp field(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      val -> val
    end
  end
end
