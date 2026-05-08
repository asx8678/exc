defmodule CodePuppyControl.Agent.LLM do
  @moduledoc """
  Behaviour definition for the LLM client used by Agent.Loop.

  ## TODO

  This module defines the interface that `CodePuppyControl.LLM` (being built)
  should implement. Once complete, this behaviour can
  be moved into the LLM module directly, or `Agent.Loop` can reference
  `CodePuppyControl.LLM` directly.

  For now, test code should pass a mock module via `opts[:llm_module]`.

  ## Expected Interface

  The LLM module must implement `stream_chat/4`:

      stream_chat(messages, tools, opts, callback_fn) :: {:ok, response} | {:error, reason}

  Where:
  - `messages` — List of message maps (`%{role: ..., content: ...}`)
  - `tools` — List of tool atom names
  - `opts` — Keyword list with `:model`, `:system_prompt`, etc.
  - `callback_fn` — Function called with stream events:
    - `{:text, chunk}` — Text content chunk
    - `{:tool_call, name, args, id}` — Tool call request
    - `{:done, reason}` — Stream complete
  - Response: `%{text: String.t(), tool_calls: [%{id: ..., name: ..., arguments: ...}]}`
  """

  @doc """
  Streams a chat completion from the LLM.

  See module doc for full interface specification.
  """
  @callback stream_chat(
              messages :: [map()],
              tools :: [atom()],
              opts :: keyword(),
              callback_fn :: (term() -> any())
            ) :: {:ok, map()} | {:error, term()}
end
