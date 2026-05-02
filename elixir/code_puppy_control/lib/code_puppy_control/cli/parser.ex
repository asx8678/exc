defmodule CodePuppyControl.CLI.Parser do
  @moduledoc """
  OptionParser for the `pup` / `code-puppy` CLI.

  Separated from `CodePuppyControl.CLI` for testability —
  parsing logic is pure and requires no OTP supervision tree.
  """

  @strict [
    help: :boolean,
    version: :boolean,
    model: :string,
    agent: :string,
    continue: :boolean,
    prompt: :string,
    interactive: :boolean,
    bridge_mode: :boolean,
    worker: :boolean,
    sname: :string,
    name: :string,
    cookie: :string
  ]

  @aliases [
    h: :help,
    v: :version,
    V: :version,
    m: :model,
    a: :agent,
    c: :continue,
    p: :prompt,
    i: :interactive,
    w: :worker
  ]

  @doc """
  Parse CLI arguments and return a tagged result.

  ## Returns

    * `{:help, opts}`       - `--help` / `-h` was given
    * `{:version, opts}`    - `--version` / `-v` / `-V` was given
    * `{:ok, opts}`         - Valid arguments, parsed into a map
    * `{:error, message}`  - Invalid arguments or conflicting flags
  """
  @spec parse([String.t()]) ::
          {:help, map()} | {:version, map()} | {:ok, map()} | {:error, String.t()}
  def parse(args) do
    case OptionParser.parse(args, strict: @strict, aliases: @aliases) do
      {parsed, positional, []} ->
        opts = build_opts(parsed, positional)

        cond do
          opts[:help] -> {:help, opts}
          opts[:version] -> {:version, opts}
          true -> {:ok, opts}
        end

      {_parsed, _positional, invalid} ->
        errors = Enum.map_join(invalid, ", ", fn {key, _val} -> to_string(key) end)
        {:error, "unknown option(s): #{errors}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_opts(parsed, positional) do
    base =
      parsed
      |> Enum.into(%{})
      |> Map.update(:model, nil, & &1)
      |> Map.update(:agent, nil, & &1)
      |> Map.update(:prompt, nil, & &1)

    # Positional args: the first one becomes the prompt if -p not given
    base =
      case {base[:prompt], positional} do
        {nil, [first | _]} -> Map.put(base, :prompt, first)
        _ -> base
      end

    # Ensure boolean keys are present
    base
    |> Map.put_new(:help, false)
    |> Map.put_new(:version, false)
    |> Map.put_new(:continue, false)
    |> Map.put_new(:interactive, false)
    |> Map.put_new(:bridge_mode, false)
    |> Map.put_new(:worker, false)
    |> Map.put_new(:sname, nil)
    |> Map.put_new(:name, nil)
    |> Map.put_new(:cookie, nil)
  end
end
