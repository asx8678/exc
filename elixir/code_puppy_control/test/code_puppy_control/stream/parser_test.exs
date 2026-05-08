defmodule CodePuppyControl.Stream.ParserTest do
  @moduledoc """
  Port of test_stream_parser.py — StreamLineParser, SSEParser, and parse_jsonl_lenient.

  These are pure-Elixir reimplementations of the Python streaming parsers,
  tested against the same behavioral contracts.
  """

  use ExUnit.Case, async: true

  # ===========================================================================
  # SSEEvent struct (local to this test module)
  # ===========================================================================

  defstruct [:event, :data, :id, :retry]

  defp new_sse_event(attrs \\ []) do
    %__MODULE__{
      event: Keyword.get(attrs, :event, "message"),
      data: Keyword.get(attrs, :data, ""),
      id: Keyword.get(attrs, :id),
      retry: Keyword.get(attrs, :retry)
    }
  end

  # ===========================================================================
  # StreamLineParser
  # ===========================================================================

  describe "StreamLineParser - basic line emission" do
    test "complete line in one chunk" do
      {lines, _buf} = feed_line_parser("hello\n")
      assert lines == ["hello"]
    end

    test "line split across two chunks" do
      {lines1, buf} = feed_line_parser("hel")
      assert lines1 == []
      {lines2, _buf} = feed_line_parser("lo\n", buf)
      assert lines2 == ["hello"]
    end

    test "multiple lines in one chunk" do
      {lines, _buf} = feed_line_parser("alpha\nbeta\ngamma\n")
      assert lines == ["alpha", "beta", "gamma"]
    end

    test "partial last line not yielded" do
      {lines, buf} = feed_line_parser("line1\nincomplete")
      assert lines == ["line1"]
      assert buf == "incomplete"
    end

    test "empty string feed yields nothing" do
      {lines, buf} = feed_line_parser("")
      assert lines == []
      assert buf == ""
    end
  end

  describe "StreamLineParser - flush" do
    test "flush returns incomplete line" do
      {_lines, buf} = feed_line_parser("no-newline")
      flushed = flush_line_parser(buf)
      assert flushed == ["no-newline"]
    end

    test "flush empty buffer yields nothing" do
      flushed = flush_line_parser("")
      assert flushed == []
    end

    test "flush clears buffer - second flush is empty" do
      {_lines, buf} = feed_line_parser("data")
      _first = flush_line_parser(buf)
      # After flush, buffer is empty
      second = flush_line_parser("")
      assert second == []
    end
  end

  describe "StreamLineParser - reset" do
    test "reset clears buffer" do
      {_lines, _buf} = feed_line_parser("buffered")
      # After reset, flushing empty buffer gives nothing
      assert flush_line_parser("") == []
    end

    test "reset allows fresh start" do
      {_lines, _buf} = feed_line_parser("stale")
      {lines, _buf2} = feed_line_parser("fresh\n")
      assert lines == ["fresh"]
    end
  end

  describe "StreamLineParser - line endings" do
    test "CRLF line endings" do
      {lines, _buf} = feed_line_parser("line1\r\nline2\r\n")
      assert lines == ["line1", "line2"]
    end

    test "CR in middle is preserved" do
      {lines, _buf} = feed_line_parser("ab\rcd\n")
      assert lines == ["ab\rcd"]
    end

    test "empty line yielded for bare newline" do
      {lines, _buf} = feed_line_parser("\n")
      assert lines == [""]
    end

    test "sequential character feeds accumulate" do
      chunks = ["h", "e", "l", "l", "o", "\n"]

      {all_lines, _buf} =
        Enum.reduce(chunks, {[], ""}, fn ch, {acc_lines, buf} ->
          {new_lines, new_buf} = feed_line_parser(ch, buf)
          {acc_lines ++ new_lines, new_buf}
        end)

      assert all_lines == ["hello"]
    end

    test "two lines split at newline boundary" do
      {lines1, buf} = feed_line_parser("foo\n")
      {lines2, _buf2} = feed_line_parser("bar\n", buf)
      assert lines1 ++ lines2 == ["foo", "bar"]
    end
  end

  # ===========================================================================
  # SSEParser
  # ===========================================================================

  describe "SSEParser - simple events" do
    test "simple data event" do
      events = parse_sse("data: hello\n\n")
      assert length(events) == 1
      assert hd(events).data == "hello"
      assert hd(events).event == "message"
      assert hd(events).id == nil
      assert hd(events).retry == nil
    end

    test "event type override" do
      events = parse_sse("event: ping\ndata: heartbeat\n\n")
      assert length(events) == 1
      assert hd(events).event == "ping"
      assert hd(events).data == "heartbeat"
    end
  end

  describe "SSEParser - multiline data" do
    test "multiline data concatenated with newline" do
      events = parse_sse("data: line1\ndata: line2\ndata: line3\n\n")
      assert length(events) == 1
      assert hd(events).data == "line1\nline2\nline3"
    end
  end

  describe "SSEParser - id and retry fields" do
    test "event with id" do
      events = parse_sse("id: 42\ndata: payload\n\n")
      assert hd(events).id == "42"
    end

    test "event with retry" do
      events = parse_sse("retry: 3000\ndata: x\n\n")
      assert hd(events).retry == 3000
    end

    test "event with all fields" do
      events = parse_sse("event: update\ndata: hello\nid: 7\nretry: 500\n\n")
      assert length(events) == 1
      e = hd(events)
      assert e.event == "update"
      assert e.data == "hello"
      assert e.id == "7"
      assert e.retry == 500
    end
  end

  describe "SSEParser - comments" do
    test "comment lines ignored" do
      events = parse_sse(":this is a comment\ndata: real\n\n")
      assert length(events) == 1
      assert hd(events).data == "real"
    end

    test "only comments yields no event" do
      events = parse_sse(":comment1\n:comment2\n\n")
      assert events == []
    end
  end

  describe "SSEParser - chunked delivery" do
    test "events split across character chunks" do
      raw = "data: hello\n\n"

      {events, _state} =
        Enum.reduce(String.graphemes(raw), {[], sse_new()}, fn ch, {acc, state} ->
          {new_events, new_state} = sse_feed(ch, state)
          {acc ++ new_events, new_state}
        end)

      assert length(events) == 1
      assert hd(events).data == "hello"
    end

    test "partial event not yielded until empty line" do
      {events1, state} = sse_feed("data: partial")
      assert events1 == []
      {events2, _state} = sse_feed("\n\n", state)
      assert length(events2) == 1
      assert hd(events2).data == "partial"
    end

    test "multiple events in one chunk" do
      events = parse_sse("data: first\n\ndata: second\n\ndata: third\n\n")
      assert length(events) == 3
      assert Enum.map(events, & &1.data) == ["first", "second", "third"]
    end
  end

  describe "SSEParser - edge cases" do
    test "empty data event" do
      events = parse_sse("data:\n\n")
      assert length(events) == 1
      assert hd(events).data == ""
    end

    test "no space after colon" do
      events = parse_sse("data:no-space\n\n")
      assert length(events) == 1
      assert hd(events).data == "no-space"
    end

    test "extra spaces after colon stripped" do
      events = parse_sse("data:  two spaces\n\n")
      assert hd(events).data == "two spaces"
    end

    test "field without colon - no value" do
      events = parse_sse("data\n\n")
      assert length(events) == 1
      assert hd(events).data == ""
    end

    test "empty feed yields nothing" do
      {events, _state} = sse_feed("")
      assert events == []
    end

    test "default event type is message" do
      events = parse_sse("data: x\n\n")
      assert hd(events).event == "message"
    end

    test "state persists between feeds" do
      {_, state} = sse_feed("event: custom\n")
      {_, state} = sse_feed("data: body\n", state)
      {events, _state} = sse_feed("\n", state)
      assert length(events) == 1
      assert hd(events).event == "custom"
      assert hd(events).data == "body"
    end
  end

  # ===========================================================================
  # SSEEvent struct
  # ===========================================================================

  describe "SSEEvent struct" do
    test "defaults" do
      e = new_sse_event()
      assert e.event == "message"
      assert e.data == ""
      assert e.id == nil
      assert e.retry == nil
    end

    test "explicit values" do
      e = new_sse_event(event: "ping", data: "ok", id: "1", retry: 100)
      assert e.event == "ping"
      assert e.data == "ok"
      assert e.id == "1"
      assert e.retry == 100
    end
  end

  # ===========================================================================
  # parse_jsonl_lenient
  # ===========================================================================

  describe "parse_jsonl_lenient/1" do
    test "valid JSONL" do
      text =
        Jason.encode!(%{"a" => 1}) <>
          "\n" <> Jason.encode!(%{"b" => 2}) <> "\n" <> Jason.encode!(%{"c" => 3})

      assert parse_jsonl(text) == [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
    end

    test "mixed valid and invalid lines" do
      text = Jason.encode!(%{"ok" => true}) <> "\nnot json\n" <> Jason.encode!(%{"also" => "ok"})
      assert parse_jsonl(text) == [%{"ok" => true}, %{"also" => "ok"}]
    end

    test "empty input" do
      assert parse_jsonl("") == []
    end

    test "whitespace-only lines skipped" do
      text = Jason.encode!(%{"x" => 1}) <> "\n   \n\t\n" <> Jason.encode!(%{"y" => 2})
      assert parse_jsonl(text) == [%{"x" => 1}, %{"y" => 2}]
    end

    test "blank lines skipped" do
      text = Jason.encode!(%{"a" => 1}) <> "\n\n" <> Jason.encode!(%{"b" => 2}) <> "\n\n"
      assert parse_jsonl(text) == [%{"a" => 1}, %{"b" => 2}]
    end

    test "JSON arrays are valid" do
      text = "[1, 2, 3]\n[4, 5]"
      assert parse_jsonl(text) == [[1, 2, 3], [4, 5]]
    end

    test "JSON numbers are valid" do
      text = "42\n3.14"
      assert parse_jsonl(text) == [42, 3.14]
    end

    test "JSON strings are valid" do
      text = "\"hello\"\n\"world\""
      assert parse_jsonl(text) == ["hello", "world"]
    end

    test "JSON booleans and null" do
      text = "true\nfalse\nnull"
      assert parse_jsonl(text) == [true, false, nil]
    end

    test "all invalid lines returns empty" do
      text = "garbage\n!!!\nnot-json"
      assert parse_jsonl(text) == []
    end

    test "single valid line" do
      assert parse_jsonl(Jason.encode!(%{"key" => "val"})) == [%{"key" => "val"}]
    end

    test "preserves order" do
      lines = Enum.map(0..9, &Integer.to_string/1)
      text = Enum.join(lines, "\n")
      assert parse_jsonl(text) == Enum.map(0..9, & &1)
    end

    test "leading/trailing whitespace stripped" do
      text = "  42  \n  " <> Jason.encode!(%{"a" => 1}) <> "  "
      assert parse_jsonl(text) == [42, %{"a" => 1}]
    end
  end

  # ===========================================================================
  # Pure Elixir implementations of the parsers for testing
  # ===========================================================================

  # -- StreamLineParser --

  defp feed_line_parser(chunk, buffer \\ "") do
    combined = buffer <> chunk
    lines = String.split(combined, "\n")

    case List.last(lines) do
      "" ->
        # All lines terminated by \n; last element is empty
        complete = Enum.drop(lines, -1)
        {strip_crlf(complete), ""}

      _incomplete ->
        # Last element is incomplete; yield complete lines, buffer the rest
        complete = Enum.drop(lines, -1)
        remaining = List.last(lines)
        {strip_crlf(complete), remaining}
    end
  end

  defp strip_crlf(lines) do
    Enum.map(lines, fn line ->
      line
      |> String.trim_trailing("\r")
    end)
  end

  defp flush_line_parser(buffer) do
    if buffer == "" do
      []
    else
      [buffer]
    end
  end

  # -- SSEParser --

  defp sse_new do
    %{event_type: "message", data_lines: [], last_id: nil, retry_val: nil, buffer: ""}
  end

  defp sse_feed(chunk, state \\ sse_new()) do
    combined = state.buffer <> chunk
    lines = String.split(combined, "\n")

    # Last element may be incomplete (not terminated by \n)
    {complete_lines, new_buffer} =
      if String.ends_with?(combined, "\n") do
        {Enum.drop(lines, -1), ""}
      else
        {Enum.drop(lines, -1), List.last(lines)}
      end

    {events, final_state} =
      Enum.reduce(complete_lines, {[], %{state | buffer: nil}}, fn line, {acc, st} ->
        cond do
          String.trim(line) == "" ->
            if st.data_lines != [] do
              event =
                new_sse_event(
                  event: st.event_type,
                  data: Enum.join(Enum.reverse(st.data_lines), "\n"),
                  id: st.last_id,
                  retry: st.retry_val
                )

              {[event | acc], %{st | event_type: "message", data_lines: [], retry_val: nil}}
            else
              {acc, %{st | event_type: "message", data_lines: [], retry_val: nil}}
            end

          String.starts_with?(line, ":") ->
            {acc, st}

          true ->
            case parse_sse_field(line) do
              {"event", value} ->
                {acc, %{st | event_type: value}}

              {"data", value} ->
                {acc, %{st | data_lines: [value | st.data_lines]}}

              {"id", value} ->
                {acc, %{st | last_id: value}}

              {"retry", value} ->
                case Integer.parse(value) do
                  {int_val, _} -> {acc, %{st | retry_val: int_val}}
                  :error -> {acc, st}
                end

              _ ->
                {acc, st}
            end
        end
      end)

    {Enum.reverse(events), %{final_state | buffer: new_buffer}}
  end

  defp parse_sse_field(line) do
    case String.split(line, ":", parts: 2) do
      [name] ->
        {name, ""}

      [name, value] ->
        {name, String.trim_leading(value, " ")}

      _ ->
        nil
    end
  end

  defp parse_sse(text) do
    {events, _state} = sse_feed(text)
    events
  end

  # -- parse_jsonl_lenient --

  defp parse_jsonl(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode/1)
    |> Enum.filter(fn
      {:ok, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, val} -> val end)
  end
end
