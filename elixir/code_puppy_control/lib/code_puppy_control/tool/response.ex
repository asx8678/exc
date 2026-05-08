defmodule CodePuppyControl.Tool.Response do
  @moduledoc """
  Multimodal tool return values, replacing pydantic-ai's `ToolReturn`
  and `BinaryContent` with a unified Elixir struct.

  In pydantic-ai, tools return either plain strings, `ToolReturn` (with
  separate return_value + content + metadata), or `BinaryContent` (raw
  bytes with a media type). In Elixir we unify these into a single
  `Tool.Response` struct that covers all three cases:

  * **Text-only** — set `content` to a string (`%Response{content: "Done"}`)
  * **Binary/multimodal** — set `binary_content` + `media_type`
    (`%Response{content: "Screenshot attached", binary_content: <<...>>,
    media_type: "image/png"}`)
  * **Structured metadata** — use `metadata` for app-visible data that
    is NOT sent to the LLM

  ## Integration with Tool Behaviour

  Tools can return `{:ok, %Response{}}` from `invoke/2` and the agent
  loop will extract the appropriate parts for the LLM:

  - `content` → tool result text (always sent to LLM)
  - `binary_content` + `media_type` → attached as a UserPromptPart
  - `metadata` → available to `Agent.Behaviour.on_tool_result/3` but
    never sent to the LLM

  ## Migration from pydantic-ai

  | Python                     | Elixir (`Tool.Response`)               |
  |----------------------------|----------------------------------------|
  | `ToolReturn(return_value, content=..., metadata=...)` | `%Response{content: ..., metadata: ...}` |
  | `BinaryContent(data, media_type=...)` | `%Response{binary_content: data, media_type: "image/png"}` |
  | `ToolReturn.content`       | `response.content`                     |
  | `ToolReturn.metadata`      | `response.metadata`                    |
  | `BinaryContent.data`       | `response.binary_content`             |
  | `BinaryContent.media_type` | `response.media_type`                 |
  | `BinaryContent.base64`     | `Response.base64(response)`           |
  """

  @type media_type :: String.t()

  @type t :: %__MODULE__{
          content: String.t() | nil,
          binary_content: binary() | nil,
          media_type: media_type() | nil,
          metadata: map()
        }

  defstruct [
    :content,
    :binary_content,
    :media_type,
    metadata: %{}
  ]

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Creates a text-only tool response.

  ## Examples

      iex> resp = Response.text("File created successfully")
      iex> resp.content
      "File created successfully"
      iex> resp.binary_content
      nil
  """
  @spec text(String.t()) :: t()
  def text(content) when is_binary(content) do
    %__MODULE__{content: content}
  end

  @doc """
  Creates a binary/multimodal tool response.

  ## Examples

      iex> png = <<137, 80, 78, 71>>  # PNG header bytes
      iex> resp = Response.binary(png, "image/png")
      iex> resp.binary_content
      <<137, 80, 78, 71>>
      iex> resp.media_type
      "image/png"
  """
  @spec binary(binary(), media_type(), String.t() | nil) :: t()
  def binary(data, media_type, content \\ nil)
      when is_binary(data) and is_binary(media_type) do
    %__MODULE__{
      content: content,
      binary_content: data,
      media_type: media_type
    }
  end

  @doc """
  Creates a tool response with both text content and metadata.

  Metadata is available to the application (e.g. `on_tool_result/3`)
  but is NOT sent to the LLM.

  ## Examples

      iex> resp = Response.with_metadata("Done", %{file_path: "/tmp/test.ex"})
      iex> resp.content
      "Done"
      iex> resp.metadata[:file_path]
      "/tmp/test.ex"
  """
  @spec with_metadata(String.t(), map()) :: t()
  def with_metadata(content, metadata)
      when is_binary(content) and is_map(metadata) do
    %__MODULE__{content: content, metadata: metadata}
  end

  @doc """
  Returns the base64-encoded string of the binary content.

  Equivalent to pydantic-ai's `BinaryContent.base64` property.
  Returns `nil` if no binary content is present.

  ## Examples

      iex> resp = Response.binary(<<1, 2, 3>>, "application/octet-stream")
      iex> Response.base64(resp)
      "AQID"

      iex> resp = Response.text("hello")
      iex> Response.base64(resp)
      nil
  """
  @spec base64(t()) :: String.t() | nil
  def base64(%__MODULE__{binary_content: nil}), do: nil

  def base64(%__MODULE__{binary_content: data}) when is_binary(data) do
    Base.encode64(data)
  end

  @doc """
  Returns `true` if this response contains binary content.

  ## Examples

      iex> Response.binary?(Response.binary(<<1>>, "image/png"))
      true

      iex> Response.binary?(Response.text("hello"))
      false
  """
  @spec binary?(t()) :: boolean()
  def binary?(%__MODULE__{binary_content: nil}), do: false
  def binary?(%__MODULE__{binary_content: _data}), do: true

  @doc """
  Converts the response to a plain map for serialization.

  Binary content is base64-encoded in the map (matching
  pydantic-ai's `ser_json_bytes='base64'` config).

  ## Examples

      iex> resp = Response.text("hello")
      iex> map = Response.to_map(resp)
      iex> map["content"]
      "hello"
      iex> map["binary_content"]
      nil
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = resp) do
    %{
      "content" => resp.content,
      "binary_content" => resp.binary_content && Base.encode64(resp.binary_content),
      "media_type" => resp.media_type,
      "metadata" => resp.metadata
    }
  end

  @doc """
  Merges additional metadata into the response.

  Existing metadata keys are overridden by `extra`.

  ## Examples

      iex> resp = Response.with_metadata("ok", %{a: 1})
      iex> resp = Response.merge_metadata(resp, %{b: 2})
      iex> resp.metadata
      %{a: 1, b: 2}
  """
  @spec merge_metadata(t(), map()) :: t()
  def merge_metadata(%__MODULE__{metadata: existing} = resp, extra) when is_map(extra) do
    %{resp | metadata: Map.merge(existing, extra)}
  end
end
