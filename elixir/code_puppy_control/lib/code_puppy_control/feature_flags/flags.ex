defmodule CodePuppyControl.FeatureFlags.Flags do
  @moduledoc """
  Feature-flag capability definitions for ADR-004 Phase H gradual rollout.

  Each capability corresponds to a code path that can be independently
  toggled between Python and Elixir runtimes. Flags are stored in
  `~/.code_puppy_ex/flags.json` with the `elixir.` prefix.

  ## Known Capabilities

  | Flag Key               | Description                       |
  |------------------------|-----------------------------------|
  | `elixir.llm_client`    | Route LLM client calls to Elixir  |
  | `elixir.base_agent`    | Route agent execution to Elixir   |
  | `elixir.tools`         | Route tool dispatch to Elixir     |
  | `elixir.plugins`       | Load plugins via Elixir loader    |
  | `elixir.cli`           | Route CLI/REPL to Elixir          |

  These map directly to the ADR-004 Phase H flag spec.
  """

  @known_capabilities [
    {:llm_client, "Route LLM client calls to Elixir"},
    {:base_agent, "Route agent execution to Elixir"},
    {:tools, "Route tool dispatch to Elixir"},
    {:plugins, "Load plugins via Elixir loader"},
    {:cli, "Route CLI/REPL to Elixir"}
  ]

  @doc "Returns all known capability definitions as `[{atom, description}]`."
  @spec all() :: [{atom(), String.t()}]
  def all, do: @known_capabilities

  @doc "Returns all known capability atoms."
  @spec names() :: [atom()]
  def names, do: Enum.map(@known_capabilities, fn {name, _desc} -> name end)

  @doc "Checks whether `name` is a known capability atom."
  @spec known?(atom()) :: boolean()
  def known?(name) when is_atom(name), do: name in names()
  def known?(_), do: false

  @doc """
  Resolves a capability flag to its canonical atom form.

  Accepts both `\"llm_client\"` (with or without `elixir.` prefix) and
  `:llm_client` atoms. Returns `{:ok, atom}` if known, `{:error, :unknown}`
  otherwise.

  ## Examples

      iex> CodePuppyControl.FeatureFlags.Flags.resolve("llm_client")
      {:ok, :llm_client}

      iex> CodePuppyControl.FeatureFlags.Flags.resolve(:llm_client)
      {:ok, :llm_client}

      iex> CodePuppyControl.FeatureFlags.Flags.resolve("elixir.llm_client")
      {:ok, :llm_client}

      iex> CodePuppyControl.FeatureFlags.Flags.resolve(:nonexistent)
      {:error, :unknown}
  """
  @spec resolve(atom() | String.t()) :: {:ok, atom()} | {:error, :unknown}
  def resolve(name) when is_atom(name) do
    if known?(name), do: {:ok, name}, else: {:error, :unknown}
  end

  def resolve(name) when is_binary(name) do
    stripped =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("elixir.", "")

    known_names = names()

    case Enum.find(known_names, fn atom -> Atom.to_string(atom) == stripped end) do
      nil -> {:error, :unknown}
      atom -> {:ok, atom}
    end
  end

  @doc "Returns the full JSON key for a capability (e.g. `\"elixir.llm_client\"`)."
  @spec json_key(atom()) :: String.t()
  def json_key(capability) when is_atom(capability) do
    "elixir.#{capability}"
  end
end
