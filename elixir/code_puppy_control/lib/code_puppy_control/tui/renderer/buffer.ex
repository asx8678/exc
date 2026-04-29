defmodule CodePuppyControl.TUI.Renderer.Buffer do
  @moduledoc """
  Buffer flush logic for the TUI Renderer.

  Handles flushing of accumulated text and thinking deltas
  from the per-part-index buffers, rendering them via Markdown
  and Owl output.
  """

  alias CodePuppyControl.TUI.Markdown
  alias CodePuppyControl.TUI.Renderer.OwlOutput

  @doc """
  Flush the text buffer for a single part index.
  Returns the updated text_buffer map.
  """
  @spec flush_text_buffer(%{non_neg_integer() => iolist()}, non_neg_integer()) ::
          %{non_neg_integer() => iolist()}
  def flush_text_buffer(text_buffer, idx) do
    chunks = Map.get(text_buffer, idx, [])

    if chunks != [] do
      text = IO.iodata_to_binary(chunks)
      OwlOutput.owl_puts(Markdown.render(text))
    end

    Map.put(text_buffer, idx, [])
  end

  @doc """
  Flush all text buffers. Returns an empty text_buffer map.
  """
  @spec flush_all_text_buffers(%{non_neg_integer() => iolist()}) ::
          %{non_neg_integer() => iolist()}
  def flush_all_text_buffers(text_buffer) do
    text_buffer
    |> Enum.each(fn {_idx, chunks} ->
      if chunks != [] do
        text = IO.iodata_to_binary(chunks)
        OwlOutput.owl_puts(Markdown.render(text))
      end
    end)

    %{}
  end

  @doc """
  Flush all thinking buffers (rendered dimmed).
  Returns an empty thinking_buffer map.
  """
  @spec flush_all_thinking_buffers(%{non_neg_integer() => iolist()}) ::
          %{non_neg_integer() => iolist()}
  def flush_all_thinking_buffers(thinking_buffer) do
    thinking_buffer
    |> Enum.each(fn {_idx, chunks} ->
      if chunks != [] do
        text = IO.iodata_to_binary(chunks)
        OwlOutput.owl_puts(Owl.Data.tag(Markdown.render(text), :faint))
      end
    end)

    %{}
  end
end
