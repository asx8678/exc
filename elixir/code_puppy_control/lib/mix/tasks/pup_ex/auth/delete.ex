defmodule Mix.Tasks.PupEx.Auth.Delete do
  @shortdoc "Delete a credential from the encrypted store"
  @moduledoc """
  Delete a named credential from the encrypted credential store.

  This operation is idempotent — deleting a non-existent key is not an
  error.

  ## Usage

      mix pup_ex.auth.delete OPENAI_API_KEY

  ## Isolation

  This task only deletes from `~/.code_puppy_ex/credentials/`. It never
  modifies anything under `~/.code_puppy/`.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix pup_ex.auth.delete <KEY_NAME>")
    exit({:shutdown, 1})
  end

  def run([key_name | _rest]) do
    existed? = CodePuppyControl.Credentials.exists?(key_name)

    case CodePuppyControl.Credentials.delete(key_name) do
      :ok when existed? ->
        Mix.shell().info("✓ Deleted credential '#{key_name}'")

      :ok ->
        Mix.shell().info("No credential named '#{key_name}' was stored (noop)")

      {:error, reason} ->
        Mix.shell().error("Failed to delete credential: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
