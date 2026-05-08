defmodule CodePuppyControl.MessageCore.Types do
  @moduledoc """
  Shared type definitions for message processing modules.

  This is a delegation wrapper around `CodePuppyControl.Messages.Types`.
  All types are re-exported from the existing implementation.

  ## Migration Path

  Use `MessageCore.Types` for new code to match the Python namespace structure.
  The existing `Messages.Types` remains available for backward compatibility.
  """

  @typedoc "A single part of a message (text, tool call, or tool result)"
  @type message_part :: CodePuppyControl.Messages.Types.message_part()

  @typedoc "A complete message with metadata and parts"
  @type message :: CodePuppyControl.Messages.Types.message()

  @typedoc "Definition of a tool available to the model"
  @type tool_definition :: CodePuppyControl.Messages.Types.tool_definition()

  # Convenience aliases for module use
  @type t :: message()
  @type part :: message_part()
  @type tool :: tool_definition()
end
