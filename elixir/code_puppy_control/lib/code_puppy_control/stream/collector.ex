defmodule CodePuppyControl.Stream.Collector do
  @moduledoc """
  Accumulator for assembling full responses from canonical stream events.

  Given a stream of `CodePuppyControl.Stream.Event` structs, produces a final
  response map with full text content, tool calls, usage, and metadata.

  ## Design

  Pure reducer — no processes, no side effects. Feed events via `collect/2`,
  extract the final result with `to_response/1`.

  Handles interleaved text + tool calls correctly by tracking parts by index.

  ## Usage

      collector = Collector.new()

      collector =
        collector
        |> Collector.collect(%TextStart{index: 0, id: nil})
        |> Collector.collect(%TextDelta{index: 0, text: "Hello "})
        |> Collector.collect(%TextDelta{index: 0, text: "world!"})
        |> Collector.collect(%TextEnd{index: 0, id: nil})
        |> Collector.collect(%Done{id: "msg-1", model: "gpt-4o", finish_reason: "stop", usage: nil})

      Collector.to_response(collector)
      #=> %{id: "msg-1", model: "gpt-4o", content: "Hello world!", tool_calls: [], ...}

  ## One-shot collection

      response = Collector.collect_stream(events)
  """

  alias CodePuppyControl.Stream.Event

  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: String.t() | nil,
          finish_reason: String.t() | nil,
          usage: map() | nil,
          text_parts: %{non_neg_integer() => [String.t()]},
          tool_call_parts: %{
            non_neg_integer() => %{
              id: String.t() | nil,
              name: String.t() | nil,
              arg_chunks: [String.t()]
            }
          }
        }

  defstruct [
    :id,
    :model,
    :finish_reason,
    :usage,
    text_parts: %{},
    tool_call_parts: %{}
  ]

  @doc """
  Creates a new empty collector.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Processes a single canonical stream event, updating the accumulator.

  ## Examples

      iex> Collector.new() |> Collector.collect(%TextDelta{index: 0, text: "hi"})
      %Collector{text_parts: %{0 => ["hi"]}}
  """
  @spec collect(t(), Event.canonical()) :: t()
  def collect(%__MODULE__{} = acc, %Event.TextStart{}) do
    acc
  end

  def collect(%__MODULE__{} = acc, %Event.TextDelta{index: idx, text: text}) do
    chunks = Map.get(acc.text_parts, idx, [])
    %{acc | text_parts: Map.put(acc.text_parts, idx, [text | chunks])}
  end

  def collect(%__MODULE__{} = acc, %Event.TextEnd{}) do
    acc
  end

  def collect(%__MODULE__{} = acc, %Event.ToolCallStart{index: idx, id: id, name: name}) do
    part =
      Map.get(acc.tool_call_parts, idx, %{id: nil, name: nil, arg_chunks: []})

    part =
      part
      |> maybe_put_tool_id(id)
      |> maybe_put_tool_name(name)

    %{acc | tool_call_parts: Map.put(acc.tool_call_parts, idx, part)}
  end

  def collect(%__MODULE__{} = acc, %Event.ToolCallArgsDelta{index: idx, arguments: args}) do
    part =
      Map.get(acc.tool_call_parts, idx, %{id: nil, name: nil, arg_chunks: []})

    part = %{part | arg_chunks: [args | part.arg_chunks]}
    %{acc | tool_call_parts: Map.put(acc.tool_call_parts, idx, part)}
  end

  def collect(%__MODULE__{} = acc, %Event.ToolCallEnd{
        index: idx,
        id: id,
        name: name,
        arguments: args
      }) do
    part =
      Map.get(acc.tool_call_parts, idx, %{id: nil, name: nil, arg_chunks: []})

    part =
      part
      |> maybe_put_tool_id(id)
      |> maybe_put_tool_name(name)
      |> then(fn p ->
        cond do
          # ToolCallEnd with full arguments is authoritative - replace delta chunks
          args && args != "" ->
            %{p | arg_chunks: [args]}

          # No arguments in end event, keep accumulated deltas
          true ->
            p
        end
      end)

    %{acc | tool_call_parts: Map.put(acc.tool_call_parts, idx, part)}
  end

  def collect(%__MODULE__{} = acc, %Event.Done{} = done) do
    %{
      acc
      | id: done.id || acc.id,
        model: done.model || acc.model,
        finish_reason: done.finish_reason || acc.finish_reason,
        usage: if(done.usage, do: usage_to_map(done.usage), else: acc.usage)
    }
  end

  # Thinking events — accumulate but don't include in response for now
  def collect(%__MODULE__{} = acc, %Event.ThinkingStart{}) do
    acc
  end

  def collect(%__MODULE__{} = acc, %Event.ThinkingDelta{}) do
    acc
  end

  def collect(%__MODULE__{} = acc, %Event.ThinkingEnd{}) do
    acc
  end

  def collect(%__MODULE__{} = acc, %Event.UsageUpdate{} = usage) do
    %{acc | usage: usage_to_map(usage)}
  end

  @doc """
  Converts the accumulated state into a final response map.

  The response follows the same shape as `CodePuppyControl.LLM.Provider.response/0`.

  ## Examples

      iex> collector = Collector.new()
      ...>   |> Collector.collect(%TextDelta{index: 0, text: "Hello"})
      ...>   |> Collector.collect(%Done{id: "x", model: "gpt-4o", finish_reason: "stop", usage: nil})
      ...> Collector.to_response(collector).content
      "Hello"
  """
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = acc) do
    content =
      acc.text_parts
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map_join(fn {_idx, chunks} ->
        chunks |> Enum.reverse() |> Enum.join()
      end)
      |> then(fn t -> if t == "", do: nil, else: t end)

    tool_calls =
      acc.tool_call_parts
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, part} ->
        args_json = part.arg_chunks |> Enum.reverse() |> Enum.join()

        %{
          id: part.id || "",
          name: part.name || "",
          arguments: parse_arguments(args_json)
        }
      end)

    %{
      id: acc.id || "",
      model: acc.model || "",
      content: content,
      tool_calls: tool_calls,
      finish_reason: acc.finish_reason,
      usage: acc.usage || %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }
  end

  @doc """
  Convenience function: collects a list of canonical events and returns the final response.

  ## Examples

      iex> Collector.collect_stream([%TextDelta{index: 0, text: "Hi"}, %Done{id: "1", model: "m", finish_reason: "stop", usage: nil}]).content
      "Hi"
  """
  @spec collect_stream([Event.canonical()]) :: map()
  def collect_stream(events) when is_list(events) do
    events
    |> Enum.reduce(new(), &collect(&2, &1))
    |> to_response()
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp maybe_put_tool_id(part, nil), do: part
  defp maybe_put_tool_id(part, id), do: %{part | id: id}

  defp maybe_put_tool_name(part, nil), do: part
  defp maybe_put_tool_name(part, name), do: %{part | name: name}

  defp parse_arguments(nil), do: %{}
  defp parse_arguments(""), do: %{}

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> args
    end
  end

  defp parse_arguments(args), do: args

  defp usage_to_map(%Event.UsageUpdate{} = u) do
    %{
      prompt_tokens: u.prompt_tokens || 0,
      completion_tokens: u.completion_tokens || 0,
      total_tokens: u.total_tokens || 0
    }
  end
end
