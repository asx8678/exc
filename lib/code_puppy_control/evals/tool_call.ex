defmodule CodePuppyControl.Evals.ToolCall do
  @moduledoc """
  A single tool call captured from an agent run.

  Mirrors Python `ToolCall` dataclass in `evals/eval_helpers.py`.

  JSON shape: `%{"name" => string, "args" => map, "result" => string | nil}`
  """

  @enforce_keys [:name, :args]
  defstruct [:name, :args, :result]

  @type t :: %__MODULE__{
          name: String.t(),
          args: map(),
          result: String.t() | nil
        }

  @doc """
  Build a ToolCall struct.

  ## Examples

      iex> CodePuppyControl.Evals.ToolCall.new("read_file", %{"path" => "README.md"})
      %CodePuppyControl.Evals.ToolCall{name: "read_file", args: %{"path" => "README.md"}, result: nil}

      iex> CodePuppyControl.Evals.ToolCall.new("read_file", %{"path" => "a.ex"}, "# hello")
      %CodePuppyControl.Evals.ToolCall{name: "read_file", args: %{"path" => "a.ex"}, result: "# hello"}
  """
  @spec new(String.t(), map(), String.t() | nil) :: t()
  def new(name, args, result \\ nil) when is_binary(name) and is_map(args) do
    %__MODULE__{name: name, args: args, result: result}
  end

  @doc """
  Serialize to plain map matching Python JSON keys.

  ## Example

      iex> tc = CodePuppyControl.Evals.ToolCall.new("read_file", %{"path" => "a.ex"}, "ok")
      iex> CodePuppyControl.Evals.ToolCall.to_map(tc)
      %{"name" => "read_file", "args" => %{"path" => "a.ex"}, "result" => "ok"}
  """
  @spec to_map(t()) :: %{String.t() => any()}
  def to_map(%__MODULE__{name: n, args: a, result: r}) do
    %{"name" => n, "args" => a, "result" => r}
  end
end
