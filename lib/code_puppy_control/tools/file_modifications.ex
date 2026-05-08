defmodule CodePuppyControl.Tools.FileModifications do
  @moduledoc """
  Umbrella module for all file modification tools.

  Registers all file modification tools with the Tool.Registry:

  - `CreateFile` — create new files or overwrite existing
  - `ReplaceInFile` — targeted text replacements (exact/fuzzy matching)
  - `EditFile` — comprehensive editor (dispatches to create/replace/delete)
  - `DeleteFile` — safely delete files
  - `DeleteSnippet` — remove first occurrence of a text snippet

  Supporting modules:

  - `SafeWrite` — symlink-safe file writing (O_NOFOLLOW equivalent)
  - `FileLock` — per-file locking for concurrent mutation serialization (`:global.trans/3`)
  - `Validation` — post-edit syntax validation (advisory only, Elixir/Erlang/JSON only)
  - `DiffEmitter` — structured diff message emission for UI display

  > **Note:** User rejection / policy denial responses are handled directly by each
  > tool's `permission_check/2` callback via `FileOps.Security.validate_path/2`. There
  > is no separate Permissions module.

  ## Usage

      # Register all tools at startup
      CodePuppyControl.Tools.FileModifications.register_all()

      # Or call individual tools via Runner
      CodePuppyControl.Tool.Runner.invoke(:replace_in_file, %{
        "file_path" => "lib/foo.ex",
        "replacements" => [%{"old_str" => "bar", "new_str" => "baz"}]
      }, %{})
  """

  require Logger

  alias CodePuppyControl.Tool.Registry

  @doc """
  Returns the list of all file modification tool modules.
  """
  @spec tool_modules() :: [module()]
  def tool_modules do
    [
      __MODULE__.CreateFile,
      __MODULE__.ReplaceInFile,
      __MODULE__.EditFile,
      __MODULE__.DeleteFile,
      __MODULE__.DeleteSnippet
    ]
  end

  @doc """
  Returns the list of all supporting modules (not tools themselves).
  """
  @spec support_modules() :: [module()]
  def support_modules do
    [
      __MODULE__.SafeWrite,
      __MODULE__.FileLock,
      __MODULE__.Validation,
      __MODULE__.DiffEmitter
    ]
  end

  @doc """
  Registers all file modification tools with the Tool Registry.

  Returns `{:ok, count}` where count is the number of tools successfully registered.
  """
  @spec register_all() :: {:ok, non_neg_integer()}
  def register_all do
    modules = tool_modules()

    Enum.reduce(modules, {:ok, 0}, fn module, {:ok, acc} ->
      case Registry.register(module) do
        :ok ->
          {:ok, acc + 1}

        {:error, reason} ->
          Logger.warning("Failed to register #{inspect(module)}: #{reason}")
          {:ok, acc}
      end
    end)
  end
end
