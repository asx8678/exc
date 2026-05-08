defmodule CodePuppyControl.CLI.GacParser do
  @moduledoc """
  OptionParser for the `gac` CLI.

  Separated from `CodePuppyControl.CLI.Gac` for testability.
  """

  @strict [
    help: :boolean,
    message: :string,
    no_push: :boolean,
    dry_run: :boolean,
    no_stage: :boolean
  ]

  @aliases [
    h: :help,
    m: :message
  ]

  @doc """
  Parse GAC CLI arguments.

  ## Returns

    * `{:help, opts}`       - `--help` / `-h` was given
    * `{:ok, opts}`         - Valid arguments, parsed into a map
    * `{:error, message}`  - Invalid arguments
  """
  @spec parse([String.t()]) ::
          {:help, map()} | {:ok, map()} | {:error, String.t()}
  def parse(args) do
    case OptionParser.parse(args, strict: @strict, aliases: @aliases) do
      {parsed, _positional, []} ->
        opts =
          parsed
          |> Enum.into(%{})
          |> Map.put_new(:help, false)
          |> Map.put_new(:no_push, false)
          |> Map.put_new(:dry_run, false)
          |> Map.put_new(:no_stage, false)

        if opts[:help] do
          {:help, opts}
        else
          {:ok, opts}
        end

      {_parsed, _positional, invalid} ->
        errors = Enum.map_join(invalid, ", ", fn {key, _val} -> to_string(key) end)
        {:error, "unknown option(s): #{errors}"}
    end
  end
end
