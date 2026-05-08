defmodule CodePuppyControl.Indexer.FileSummary do
  @moduledoc """
  Represents a summarized file from directory indexing.
  """

  @enforce_keys [:path, :kind]
  defstruct [:path, :kind, symbols: []]

  @type t :: %__MODULE__{
          path: String.t(),
          kind: String.t(),
          symbols: [String.t()]
        }

  @doc """
  Creates a new FileSummary struct.

  ## Examples

      iex> FileSummary.new("lib/app.ex", "elixir")
      %FileSummary{path: "lib/app.ex", kind: "elixir", symbols: []}

      iex> FileSummary.new("lib/app.ex", "elixir", ["defmodule App"])
      %FileSummary{path: "lib/app.ex", kind: "elixir", symbols: ["defmodule App"]}
  """
  @spec new(String.t(), String.t(), [String.t()]) :: t()
  def new(path, kind, symbols \\ []) do
    %__MODULE__{
      path: path,
      kind: kind,
      symbols: symbols
    }
  end

  @doc """
  Converts a FileSummary to a JSON-serializable map.

  ## Examples

      iex> summary = %FileSummary{path: "lib/app.ex", kind: "elixir", symbols: ["def start"]}
      iex> FileSummary.to_map(summary)
      %{"path" => "lib/app.ex", "kind" => "elixir", "symbols" => ["def start"]}
  """
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = summary) do
    %{
      "path" => summary.path,
      "kind" => summary.kind,
      "symbols" => summary.symbols
    }
  end

  @doc """
  Converts a list of FileSummaries to JSON-serializable maps.

  ## Examples

      iex> summaries = [%FileSummary{path: "lib/app.ex", kind: "elixir", symbols: []}]
      iex> FileSummary.to_maps(summaries)
      [%{"path" => "lib/app.ex", "kind" => "elixir", "symbols" => []}]
  """
  @spec to_maps([t()]) :: [%{String.t() => term()}]
  def to_maps(summaries) when is_list(summaries) do
    Enum.map(summaries, &to_map/1)
  end
end
