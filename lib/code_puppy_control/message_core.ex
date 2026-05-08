defmodule CodePuppyControl.MessageCore do
  @moduledoc """
  Root namespace module for message processing functionality.

  This module provides a unified namespace for message-related operations,
  matching the Python structure for eventual port. All functionality is
  delegated to the existing implementation modules for compatibility.

  ## Submodules

    * `MessageCore.Types` - Shared type definitions for message processing
    * `MessageCore.Hasher` - Fast message hashing
    * `MessageCore.TokenEstimator` - Token estimation and batch processing
    * `MessageCore.Serializer` - MessagePack serialization
    * `MessageCore.Pruner` - Message pruning and filtering
    * `MessageCore.MessageBatch` - Message batch struct (placeholder for future work)

  ## Migration Path

  This is a wrapper layer. Existing callers using `Messages.*` and `Tokens.*`
  continue to work. New code should prefer `MessageCore.*` for consistency
  with the Python codebase.
  """

  # Re-export the Types module types for convenience
  @type message :: CodePuppyControl.MessageCore.Types.message()
  @type message_part :: CodePuppyControl.MessageCore.Types.message_part()
  @type tool_definition :: CodePuppyControl.MessageCore.Types.tool_definition()
end
