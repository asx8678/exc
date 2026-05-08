defmodule CodePuppyControl.Stream.Event do
  @moduledoc """
  Canonical streaming event types for the agent pipeline.

  Defines the structured events that flow through the streaming pipeline:
  LLM providers → Normalizer → Agent.Loop → TUI/WebSocket consumers.

  ## Event Types

  | Struct               | Purpose                                        |
  |----------------------|-------------------------------------------------|
  | `%TextStart{}`       | A new text content block begins                 |
  | `%TextDelta{}`       | A chunk of text content                         |
  | `%TextEnd{}`         | A text content block finishes                   |
  | `%ToolCallStart{}`   | A new tool call block begins                    |
  | `%ToolCallArgsDelta{}`| A chunk of tool call arguments                  |
  | `%ToolCallEnd{}`     | A tool call block finishes (with full args)      |
  | `%ThinkingStart{}`   | A thinking/reasoning block begins (Anthropic)    |
  | `%ThinkingDelta{}`   | A chunk of thinking content                      |
  | `%ThinkingEnd{}`     | A thinking block finishes                       |
  | `%UsageUpdate{}`     | Token usage information                          |
  | `%Done{}`            | Stream completed with final response             |

  ## Transport

  All events are JSON-serializable via `to_wire/1` for TUI / WebSocket / PubSub.
  Use `from_llm/1` to coerce raw LLM provider events into canonical form.

  ## Usage

      # Convert LLM provider event
      {:ok, event} = Event.from_llm({:part_delta, %{type: :text, index: 0, text: "Hi"}})

      # Serialize for transport
      wire = Event.to_wire(event)
      #=> %{"type" => "text_delta", "index" => 0, "text" => "Hi"}
  """

  # ── Struct Definitions ────────────────────────────────────────────────────

  defmodule TextStart do
    @moduledoc "A new text content block begins."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t() | nil
          }
    defstruct [:index, :id]
  end

  defmodule TextDelta do
    @moduledoc "A chunk of text content."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            text: String.t()
          }
    defstruct [:index, :text]
  end

  defmodule TextEnd do
    @moduledoc "A text content block finishes."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t() | nil
          }
    defstruct [:index, :id]
  end

  defmodule ToolCallStart do
    @moduledoc "A new tool call block begins."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t() | nil,
            name: String.t() | nil
          }
    defstruct [:index, :id, :name]
  end

  defmodule ToolCallArgsDelta do
    @moduledoc "A chunk of tool call arguments."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            arguments: String.t()
          }
    defstruct [:index, :arguments]
  end

  defmodule ToolCallEnd do
    @moduledoc "A tool call block finishes with full arguments."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t(),
            name: String.t(),
            arguments: String.t()
          }
    defstruct [:index, :id, :name, :arguments]
  end

  defmodule ThinkingStart do
    @moduledoc "A thinking/reasoning block begins (Anthropic extended thinking)."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t() | nil
          }
    defstruct [:index, :id]
  end

  defmodule ThinkingDelta do
    @moduledoc "A chunk of thinking content."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            text: String.t()
          }
    defstruct [:index, :text]
  end

  defmodule ThinkingEnd do
    @moduledoc "A thinking block finishes."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t() | nil
          }
    defstruct [:index, :id]
  end

  defmodule UsageUpdate do
    @moduledoc "Token usage information."
    @type t :: %__MODULE__{
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
    defstruct [:prompt_tokens, :completion_tokens, :total_tokens]
  end

  defmodule Done do
    @moduledoc "Stream completed with final aggregated response."
    @type t :: %__MODULE__{
            id: String.t() | nil,
            model: String.t() | nil,
            finish_reason: String.t() | nil,
            usage: UsageUpdate.t() | nil
          }
    defstruct [:id, :model, :finish_reason, :usage]
  end

  @type canonical ::
          TextStart.t()
          | TextDelta.t()
          | TextEnd.t()
          | ToolCallStart.t()
          | ToolCallArgsDelta.t()
          | ToolCallEnd.t()
          | ThinkingStart.t()
          | ThinkingDelta.t()
          | ThinkingEnd.t()
          | UsageUpdate.t()
          | Done.t()

  # ── from_llm/1 ────────────────────────────────────────────────────────────

  @doc """
  Coerces an LLM provider stream event into a canonical event.

  Accepts the raw `{:part_start, ...}`, `{:part_delta, ...}`, `{:part_end, ...}`,
  and `{:done, response}` tuples emitted by OpenAI and Anthropic providers.

  Returns `{:ok, canonical_event}` or `:skip` for unrecognized events.

  ## Examples

      iex> Event.from_llm({:part_start, %{type: :text, index: 0, id: nil}})
      {:ok, %TextStart{index: 0, id: nil}}

      iex> Event.from_llm({:part_delta, %{type: :text, index: 0, text: "hello", name: nil, arguments: nil}})
      {:ok, %TextDelta{index: 0, text: "hello"}}

      iex> Event.from_llm({:ping})
      :skip
  """
  @spec from_llm(term()) :: {:ok, canonical()} | :skip
  def from_llm({:part_start, %{type: :text} = data}) do
    {:ok, %TextStart{index: data.index, id: data.id}}
  end

  def from_llm({:part_start, %{type: :tool_call} = data}) do
    {:ok, %ToolCallStart{index: data.index, id: data.id, name: nil}}
  end

  def from_llm({:part_delta, %{type: :text} = data}) do
    {:ok, %TextDelta{index: data.index, text: data.text || ""}}
  end

  def from_llm({:part_delta, %{type: :tool_call} = data}) do
    cond do
      data[:name] && data[:name] != "" ->
        {:ok, %ToolCallStart{index: data.index, id: nil, name: data.name}}

      data[:arguments] && data[:arguments] != "" ->
        {:ok, %ToolCallArgsDelta{index: data.index, arguments: data.arguments}}

      true ->
        :skip
    end
  end

  def from_llm({:part_end, %{type: :text} = data}) do
    {:ok, %TextEnd{index: data.index, id: data.id}}
  end

  def from_llm({:part_end, %{type: :tool_call} = data}) do
    {:ok,
     %ToolCallEnd{
       index: data.index,
       id: data.id || "",
       name: data.name || "",
       arguments: data.arguments || ""
     }}
  end

  def from_llm({:done, response}) when is_map(response) do
    usage = response[:usage] || response["usage"]

    usage_event =
      if usage do
        %UsageUpdate{
          prompt_tokens: usage[:prompt_tokens] || usage["prompt_tokens"] || 0,
          completion_tokens: usage[:completion_tokens] || usage["completion_tokens"] || 0,
          total_tokens: usage[:total_tokens] || usage["total_tokens"] || 0
        }
      end

    {:ok,
     %Done{
       id: response[:id] || response["id"],
       model: response[:model] || response["model"],
       finish_reason: response[:finish_reason] || response["finish_reason"],
       usage: usage_event
     }}
  end

  def from_llm(_other), do: :skip

  # ── to_wire/1 ─────────────────────────────────────────────────────────────

  @doc """
  Serializes a canonical event to a JSON-safe map for transport.

  Suitable for `Jason.encode!/1`, PubSub broadcast, or WebSocket push.

  ## Examples

      iex> Event.to_wire(%TextDelta{index: 0, text: "hi"})
      %{"type" => "text_delta", "index" => 0, "text" => "hi"}

      iex> Event.to_wire(%ToolCallEnd{index: 0, id: "tc-1", name: "read", arguments: "{\\"path\\": \\"/f\\"}"})
      %{"type" => "tool_call_end", "index" => 0, "id" => "tc-1", "name" => "read", "arguments" => "{\\"path\\": \\"/f\\"}"}
  """
  @spec to_wire(canonical()) :: map()
  def to_wire(%TextStart{} = e) do
    %{"type" => "text_start", "index" => e.index, "id" => e.id}
  end

  def to_wire(%TextDelta{} = e) do
    %{"type" => "text_delta", "index" => e.index, "text" => e.text}
  end

  def to_wire(%TextEnd{} = e) do
    %{"type" => "text_end", "index" => e.index, "id" => e.id}
  end

  def to_wire(%ToolCallStart{} = e) do
    %{"type" => "tool_call_start", "index" => e.index, "id" => e.id, "name" => e.name}
  end

  def to_wire(%ToolCallArgsDelta{} = e) do
    %{"type" => "tool_call_args_delta", "index" => e.index, "arguments" => e.arguments}
  end

  def to_wire(%ToolCallEnd{} = e) do
    %{
      "type" => "tool_call_end",
      "index" => e.index,
      "id" => e.id,
      "name" => e.name,
      "arguments" => e.arguments
    }
  end

  def to_wire(%ThinkingStart{} = e) do
    %{"type" => "thinking_start", "index" => e.index, "id" => e.id}
  end

  def to_wire(%ThinkingDelta{} = e) do
    %{"type" => "thinking_delta", "index" => e.index, "text" => e.text}
  end

  def to_wire(%ThinkingEnd{} = e) do
    %{"type" => "thinking_end", "index" => e.index, "id" => e.id}
  end

  def to_wire(%UsageUpdate{} = e) do
    %{
      "type" => "usage_update",
      "prompt_tokens" => e.prompt_tokens,
      "completion_tokens" => e.completion_tokens,
      "total_tokens" => e.total_tokens
    }
  end

  def to_wire(%Done{} = e) do
    %{
      "type" => "done",
      "id" => e.id,
      "model" => e.model,
      "finish_reason" => e.finish_reason,
      "usage" => if(e.usage, do: to_wire(e.usage), else: nil)
    }
  end

  # ── from_wire/1 ───────────────────────────────────────────────────────────

  @doc """
  Deserializes a JSON-safe map back into a canonical event.

  Inverse of `to_wire/1`. Returns `{:ok, event}` or `{:error, :unknown_type}`.

  ## Examples

      iex> Event.from_wire(%{"type" => "text_delta", "index" => 0, "text" => "hi"})
      {:ok, %TextDelta{index: 0, text: "hi"}}
  """
  @spec from_wire(map()) :: {:ok, canonical()} | {:error, :unknown_type}
  def from_wire(%{"type" => "text_start"} = m) do
    {:ok, %TextStart{index: m["index"], id: m["id"]}}
  end

  def from_wire(%{"type" => "text_delta"} = m) do
    {:ok, %TextDelta{index: m["index"], text: m["text"]}}
  end

  def from_wire(%{"type" => "text_end"} = m) do
    {:ok, %TextEnd{index: m["index"], id: m["id"]}}
  end

  def from_wire(%{"type" => "tool_call_start"} = m) do
    {:ok, %ToolCallStart{index: m["index"], id: m["id"], name: m["name"]}}
  end

  def from_wire(%{"type" => "tool_call_args_delta"} = m) do
    {:ok, %ToolCallArgsDelta{index: m["index"], arguments: m["arguments"]}}
  end

  def from_wire(%{"type" => "tool_call_end"} = m) do
    {:ok,
     %ToolCallEnd{
       index: m["index"],
       id: m["id"] || "",
       name: m["name"] || "",
       arguments: m["arguments"] || ""
     }}
  end

  def from_wire(%{"type" => "thinking_start"} = m) do
    {:ok, %ThinkingStart{index: m["index"], id: m["id"]}}
  end

  def from_wire(%{"type" => "thinking_delta"} = m) do
    {:ok, %ThinkingDelta{index: m["index"], text: m["text"]}}
  end

  def from_wire(%{"type" => "thinking_end"} = m) do
    {:ok, %ThinkingEnd{index: m["index"], id: m["id"]}}
  end

  def from_wire(%{"type" => "usage_update"} = m) do
    {:ok,
     %UsageUpdate{
       prompt_tokens: m["prompt_tokens"] || 0,
       completion_tokens: m["completion_tokens"] || 0,
       total_tokens: m["total_tokens"] || 0
     }}
  end

  def from_wire(%{"type" => "done"} = m) do
    usage =
      case m["usage"] do
        nil ->
          nil

        u ->
          %UsageUpdate{
            prompt_tokens: u["prompt_tokens"] || 0,
            completion_tokens: u["completion_tokens"] || 0,
            total_tokens: u["total_tokens"] || 0
          }
      end

    {:ok,
     %Done{
       id: m["id"],
       model: m["model"],
       finish_reason: m["finish_reason"],
       usage: usage
     }}
  end

  def from_wire(_), do: {:error, :unknown_type}
end
