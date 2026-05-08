defmodule Mix.Tasks.PupEx.Auth.List do
  @shortdoc "List credential key names in the encrypted store"
  @moduledoc """
  List the names of credentials stored in the encrypted credential store.

  Values are NEVER printed — only the key names.

  ## Usage

      mix pup_ex.auth.list

  ## Example Output

      2 credentials stored in ~/.code_puppy_ex/credentials/store.json:
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY

  ## Isolation

  This task only reads from `~/.code_puppy_ex/credentials/`. It never
  reads the legacy Python credential paths under `~/.code_puppy/`.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    case CodePuppyControl.Credentials.list_keys() do
      {:error, reason} ->
        Mix.shell().error("Failed to read credential store: #{inspect(reason)}")
        exit({:shutdown, 1})

      [] ->
        Mix.shell().info("No credentials stored.")
        Mix.shell().info(" Add one with: mix pup_ex.auth.set <KEY_NAME>")

      keys when is_list(keys) ->
        path = CodePuppyControl.Credentials.store_path([])
        count = length(keys)
        plural = if count == 1, do: "credential", else: "credentials"

        Mix.shell().info("#{count} #{plural} stored in #{path}:")

        for key <- keys do
          Mix.shell().info(" - #{key}")
        end
    end
  end
end
