defmodule Mix.Tasks.PupEx.Auth.Set do
  @shortdoc "Store an API key or token in the encrypted credential store"
  @moduledoc """
  Store a named credential in the encrypted credential store.

  ## Usage

      # Interactive — prompts for the value (hidden echo where supported)
      mix pup_ex.auth.set OPENAI_API_KEY

      # Non-interactive — value passed on the command line (note: this may
      # leak into your shell history; the interactive form is preferred)
      mix pup_ex.auth.set OPENAI_API_KEY sk-abcdef123

      # From an environment variable — useful for CI
      mix pup_ex.auth.set OPENAI_API_KEY --from-env MY_OPENAI_KEY

  ## Isolation

  Credentials are written to `~/.code_puppy_ex/credentials/store.json`,
  encrypted with AES-256-GCM. Nothing is written under `~/.code_puppy/`.

  See `CodePuppyControl.Credentials` for the full API and encryption
  details.
  """
  use Mix.Task

  @requirements ["app.config"]

  @switches [from_env: :string]
  @aliases [e: :from_env]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.shell().error("Invalid option(s): #{inspect(invalid)}")
      exit({:shutdown, 1})
    end

    case positional do
      [key_name] ->
        value = resolve_value(opts)
        store(key_name, value)

      [key_name, value] ->
        store(key_name, value)

      [] ->
        Mix.shell().error("Usage: mix pup_ex.auth.set <KEY_NAME> [value]")
        exit({:shutdown, 1})

      _ ->
        Mix.shell().error("Too many arguments. Usage: mix pup_ex.auth.set <KEY_NAME> [value]")
        exit({:shutdown, 1})
    end
  end

  defp resolve_value(opts) do
    case Keyword.get(opts, :from_env) do
      nil ->
        prompt_for_value()

      env_var ->
        case System.get_env(env_var) do
          nil ->
            Mix.shell().error("Environment variable '#{env_var}' is not set")
            exit({:shutdown, 1})

          "" ->
            Mix.shell().error("Environment variable '#{env_var}' is empty")
            exit({:shutdown, 1})

          value ->
            value
        end
    end
  end

  defp prompt_for_value do
    value = Mix.shell().prompt("Value (input is echoed — use Ctrl-C to cancel):") |> String.trim()

    case value do
      "" ->
        Mix.shell().error("Empty value — nothing stored")
        exit({:shutdown, 1})

      v ->
        v
    end
  end

  defp store(key_name, value) do
    case CodePuppyControl.Credentials.set(key_name, value) do
      :ok ->
        Mix.shell().info("✓ Stored credential '#{key_name}' (#{byte_size(value)} bytes)")

      {:error, reason} ->
        Mix.shell().error("Failed to store credential: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
