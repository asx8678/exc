defmodule CodePuppyControl.MessageCore.Serializer do
  @moduledoc """
  MessagePack-based session serialization.

  This is a delegation wrapper around `CodePuppyControl.Messages.Serializer`.
  All functionality is delegated to the existing implementation.

  ## Usage

      alias CodePuppyControl.MessageCore.Serializer

      # Serialize messages
      {:ok, binary} = Serializer.serialize_session(messages)

      # Deserialize messages
      {:ok, messages} = Serializer.deserialize_session(binary)

  ## Migration Path

  Use `MessageCore.Serializer` for new code to match the Python namespace structure.
  The existing `Messages.Serializer` remains available for backward compatibility.
  """

  alias CodePuppyControl.Messages.Serializer, as: Impl
  alias CodePuppyControl.MessageCore.Types

  @doc """
  Serializes a list of messages to MessagePack binary format.

  Delegates to `CodePuppyControl.Messages.Serializer.serialize_session/1`.

  ## Parameters
    - messages: A list of message maps with string keys

  ## Returns
    - {:ok, binary()} on success
    - {:error, term()} on failure
  """
  @spec serialize_session([Types.message()]) :: {:ok, binary()} | {:error, term()}
  defdelegate serialize_session(messages), to: Impl

  @doc """
  Deserializes MessagePack binary data to a list of messages.

  Delegates to `CodePuppyControl.Messages.Serializer.deserialize_session/1`.

  ## Parameters
    - data: MessagePack binary data

  ## Returns
    - {:ok, [Types.message()]} on success
    - {:error, term()} on failure
  """
  @spec deserialize_session(binary()) :: {:ok, [Types.message()]} | {:error, term()}
  defdelegate deserialize_session(data), to: Impl

  @doc """
  Incrementally serializes messages by appending to existing data.

  Delegates to `CodePuppyControl.Messages.Serializer.serialize_session_incremental/2`.

  ## Parameters
    - new_messages: List of new messages to add
    - existing_data: Optional existing MessagePack binary (nil for fresh start)

  ## Returns
    - {:ok, binary()} on success
    - {:error, term()} on failure
  """
  @spec serialize_session_incremental([Types.message()], binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  defdelegate serialize_session_incremental(new_messages, existing_data \\ nil), to: Impl
end
