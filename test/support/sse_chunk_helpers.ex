defmodule CodePuppyControl.Test.SSEChunkHelpers do
  @moduledoc """
  Shared helpers for SSE chunk-boundary streaming tests.

  Provides:
  - `build_chunked_mock/1`: Returns a static mock HTTP client module that emits
    SSE data split into arbitrary chunks, exercising the real SSE parsers.
  - `split_at_points/2`: Splits a binary at given byte offsets.
  - `collect_stream/4`, `done_response/1`, `extract_text_deltas/1`,
    `extract_tool_arg_deltas/1`: Stream event collection helpers.
  - `split_points_gen/1`: StreamData generator for random split points.

  ## Mock client design

  The LLM providers call `http_client.stream(:post, url, opts)` — a module
  call, not a function invocation. So our mock must be a real module with
  `request/3` and `stream/3` functions.

  `build_chunked_mock/1` stores the chunk list in the **process dictionary**
  and returns `MockClient` — a single, pre-compiled module. Because
  `provider.stream_chat/4` is synchronous and runs in the calling (test)
  process, the process dictionary is always in scope. This avoids:

  - Atom-table leaks from dynamic `Code.compile_quoted/1` module creation.
  - `:persistent_term` entries that are never cleaned up.
  """

  defmodule MockClient do
    @moduledoc false

    defp chunk_key, do: {:sse_chunk_mock_chunks, self()}

    @doc false
    def put_chunks(chunks) do
      Process.put(chunk_key(), chunks)
    end

    @doc false
    def request(_method, _url, _opts) do
      chunks = Process.get(chunk_key())
      body = IO.iodata_to_binary(chunks)
      {:ok, %{status: 200, body: body, headers: []}}
    end

    @doc false
    def stream(_method, _url, _opts) do
      chunks = Process.get(chunk_key())

      Stream.resource(
        fn -> {chunks, false} end,
        fn
          {remaining, false} when remaining != [] ->
            {[{:data, hd(remaining)}], {tl(remaining), false}}

          {[], false} ->
            {[{:done, %{status: 200, headers: []}}], :done}

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end
  end

  @doc """
  Stores `chunks` in the process dictionary and returns `MockClient`.

  Each call overwrites the previous chunk data for the current process,
  so there is no accumulation across test runs.
  """
  def build_chunked_mock(chunks) do
    MockClient.put_chunks(chunks)
    MockClient
  end

  @doc """
  Splits `binary` at `split_points` (0-based byte offsets).
  Returns a list of binaries. Duplicate/adjacent split points are preserved,
  producing zero-length chunks that real networks can deliver.
  """
  def split_at_points(binary, split_points) do
    sorted =
      split_points
      |> Enum.sort()
      |> Enum.filter(&(&1 > 0 and &1 < byte_size(binary)))

    case sorted do
      [] -> [binary]
      points -> do_split(binary, points, 0, [])
    end
  end

  defp do_split(binary, [], _offset, acc) do
    Enum.reverse([binary | acc])
  end

  defp do_split(binary, [point | rest], offset, acc) do
    len = point - offset
    <<chunk::binary-size(len), rest_binary::binary>> = binary
    do_split(rest_binary, rest, point, [chunk | acc])
  end

  @doc """
  Collects all stream events from `provider.stream_chat/4` into a list.
  The provider sends events via `callback_fn`, which we redirect to self().
  """
  def collect_stream(provider, messages, tools, opts) do
    result =
      provider.stream_chat(messages, tools, opts, fn event ->
        send(self(), {:stream_event, event})
      end)

    collected = receive_all_stream_events([])
    {result, collected}
  end

  defp receive_all_stream_events(acc) do
    receive do
      {:stream_event, event} -> receive_all_stream_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Extracts the final `{:done, response}` from collected events.
  """
  def done_response(events) do
    Enum.find_value(events, fn
      {:done, resp} -> resp
      _ -> nil
    end)
  end

  @doc """
  Concatenates all `{:part_delta, %{type: :text, text: t}}` payloads.
  """
  def extract_text_deltas(events) do
    events
    |> Enum.filter(fn
      {:part_delta, %{type: :text, text: t}} when is_binary(t) -> true
      _ -> false
    end)
    |> Enum.map(fn {:part_delta, %{text: t}} -> t end)
    |> Enum.join()
  end

  @doc """
  Extracts tool call argument deltas, returning `%{index => concatenated_args}`.
  """
  def extract_tool_arg_deltas(events) do
    events
    |> Enum.filter(fn
      {:part_delta, %{type: :tool_call, arguments: a}}
      when is_binary(a) and a != "" ->
        true

      _ ->
        false
    end)
    |> Enum.group_by(fn {:part_delta, %{index: idx}} -> idx end)
    |> Enum.map(fn {idx, evts} ->
      args = evts |> Enum.map(fn {:part_delta, %{arguments: a}} -> a end) |> Enum.join()
      {idx, args}
    end)
    |> Map.new()
  end

  @doc """
  StreamData generator for random split points within a body of `body_size` bytes.
  """
  def split_points_gen(body_size) when body_size > 1 do
    import StreamData

    list_of(
      integer(1..(body_size - 1)),
      min_length: 1,
      max_length: 10
    )
  end

  def split_points_gen(_body_size), do: StreamData.constant([])
end
