defmodule CodePuppyControl.Messages.Serializer do
  @moduledoc """
  MessagePack-based session serialization.
  Port of code_puppy_core/src/serialization.rs.

  Uses msgpax library for MessagePack encoding/decoding.
  Round-trip compatible with existing Python sessions.
  """

  alias CodePuppyControl.Messages.Types

  @doc """
  Serializes a list of messages to MessagePack binary format.

  ## Parameters
    - messages: A list of message maps with string keys

  ## Returns
    - {:ok, binary()} on success
    - {:error, term()} on failure
  """
  @spec serialize_session([Types.message()]) :: {:ok, binary()} | {:error, term()}
  def serialize_session(messages) when is_list(messages) do
    try do
      # Msgpax.pack! returns iodata, convert to binary
      data = messages |> Msgpax.pack!() |> IO.iodata_to_binary()
      {:ok, data}
    rescue
      e -> {:error, "MessagePack serialization failed: #{inspect(e)}"}
    end
  end

  @doc """
  Deserializes MessagePack binary data to a list of messages.

  ## Parameters
    - data: MessagePack binary data

  ## Returns
    - {:ok, [Types.message()]} on success
    - {:error, term()} on failure
  """
  @spec deserialize_session(binary()) :: {:ok, [Types.message()]} | {:error, term()}
  def deserialize_session(data) when is_binary(data) do
    try do
      # Msgpax.unpack! returns the decoded term directly
      messages = Msgpax.unpack!(data)
      {:ok, messages}
    rescue
      e -> {:error, "MessagePack deserialization failed: #{inspect(e)}"}
    end
  end

  @doc """
  Incrementally serializes messages by appending to existing data.

  If existing_data is provided, it is first deserialized, then
  new_messages are appended, and the combined list is serialized.

  ## Parameters
    - new_messages: List of new messages to add
    - existing_data: Optional existing MessagePack binary (nil for fresh start)

  ## Returns
    - {:ok, binary()} on success
    - {:error, term()} on failure
  """
  @spec serialize_session_incremental([Types.message()], binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def serialize_session_incremental(new_messages, existing_data \\ nil)

  def serialize_session_incremental(new_messages, nil) do
    serialize_session(new_messages)
  end

  def serialize_session_incremental(new_messages, existing_data)
      when is_list(new_messages) and is_binary(existing_data) do
    with {:ok, existing_messages} <- deserialize_session(existing_data),
         combined = existing_messages ++ new_messages,
         {:ok, data} <- serialize_session(combined) do
      {:ok, data}
    else
      error -> error
    end
  end
end
