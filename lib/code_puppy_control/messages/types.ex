defmodule CodePuppyControl.Messages.Types do
  @moduledoc """
  Shared type definitions for message processing modules.

  These types mirror the Rust types from `code_puppy_core/src/types.rs`.
  They use simple maps rather than structs to maintain flexibility and
  compatibility with the wire protocol.

  Type definitions:

    * MessagePart - `%{part_kind: String.t(), content: String.t() | nil, 
                       content_json: String.t() | nil, tool_call_id: String.t() | nil, 
                       tool_name: String.t() | nil, args: String.t() | nil}`

    * Message - `%{kind: String.t(), role: String.t() | nil, 
                    instructions: String.t() | nil, parts: [MessagePart.t()]}`

    * ToolDefinition - `%{name: String.t(), description: String.t() | nil, 
                          input_schema: map() | nil}`
  """

  @typedoc "A single part of a message (text, tool call, or tool result)"
  @type message_part :: %{
          part_kind: String.t(),
          content: String.t() | nil,
          content_json: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          args: String.t() | nil
        }

  @typedoc "A complete message with metadata and parts"
  @type message :: %{
          kind: String.t(),
          role: String.t() | nil,
          instructions: String.t() | nil,
          parts: [message_part()]
        }

  @typedoc "Definition of a tool available to the model"
  @type tool_definition :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map() | nil
        }

  # Convenience aliases for module use
  @type t :: message()
  @type part :: message_part()
  @type tool :: tool_definition()
end
