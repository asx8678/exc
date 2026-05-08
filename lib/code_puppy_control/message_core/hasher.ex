defmodule CodePuppyControl.MessageCore.Hasher do
  @moduledoc """
  Fast message hashing for message deduplication and comparison.

  This is a delegation wrapper around `CodePuppyControl.Messages.Hasher`.
  All functionality is delegated to the existing implementation.

  ## Usage

      alias CodePuppyControl.MessageCore.Hasher

      message = %{...}  # A message conforming to Types.message()
      hash = Hasher.hash_message(message)

  ## Migration Path

  Use `MessageCore.Hasher` for new code to match the Python namespace structure.
  The existing `Messages.Hasher` remains available for backward compatibility.
  """

  alias CodePuppyControl.Messages.Hasher, as: Impl
  alias CodePuppyControl.MessageCore.Types

  @doc """
  Compute a stable hash for a message.

  Delegates to `CodePuppyControl.Messages.Hasher.hash_message/1`.

  ## Parameters

    * `msg` - A message map conforming to `Types.message()`

  ## Returns

    * `integer()` - A positive hash value
  """
  @spec hash_message(Types.message()) :: integer()
  defdelegate hash_message(msg), to: Impl

  @doc """
  Build the canonical string for a part (for hashing).

  Delegates to `CodePuppyControl.Messages.Hasher.stringify_part_for_hash/1`.

  ## Parameters

    * `part` - A message part map conforming to `Types.message_part()`

  ## Returns

    * `String.t()` - Canonical string representation
  """
  @spec stringify_part_for_hash(Types.message_part()) :: String.t()
  defdelegate stringify_part_for_hash(part), to: Impl
end
