defmodule CodePuppyControl.CLI.SlashCommands.CommandInfo do
  @moduledoc """
  Metadata for a registered slash command.

  Mirrors the Python `CommandInfo` dataclass. Each command has a primary
  name, optional aliases, a handler function, and display metadata for
  the help system.
  """

  @enforce_keys [:name, :description, :handler]
  defstruct [:name, :description, :handler, :usage, :aliases, :category, :detailed_help]

  @type handler :: (String.t(), any() -> any())
  # First arg is the raw command string (e.g., "/model gpt-4"), second is REPL state.
  # Return value is whatever the REPL loop expects: {:continue, state} | {:halt, state}.

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          handler: handler(),
          usage: String.t() | nil,
          aliases: [String.t()],
          category: String.t(),
          detailed_help: String.t() | nil
        }

  @doc """
  Creates a new CommandInfo, defaulting `usage` to `"/<name>"` when nil
  and `aliases` / `category` to their conventional defaults.

  Mirrors Python's `__post_init__` behaviour.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    name = Keyword.fetch!(attrs, :name)
    description = Keyword.fetch!(attrs, :description)
    handler = Keyword.fetch!(attrs, :handler)

    %__MODULE__{
      name: name,
      description: description,
      handler: handler,
      usage: Keyword.get(attrs, :usage, "/#{name}"),
      aliases: Keyword.get(attrs, :aliases, []),
      category: Keyword.get(attrs, :category, "core"),
      detailed_help: Keyword.get(attrs, :detailed_help)
    }
  end
end
