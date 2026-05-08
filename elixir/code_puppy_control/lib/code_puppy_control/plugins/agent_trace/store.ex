defmodule CodePuppyControl.Plugins.AgentTrace.Store do
  @moduledoc """
  NDJSON persistence for trace events.

  Append-only storage with files named by trace_id under
  `~/.code_puppy_ex/traces/`. All writes go through
  `Config.Isolation.safe_write!`.
  """

  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Plugins.AgentTrace.Schema

  @doc "Get the base directory for trace files."
  @spec base_dir() :: String.t()
  def base_dir, do: Path.join(Paths.data_dir(), "traces")

  @doc "Append an event to its trace file."
  @spec append(Schema.trace_event()) :: boolean()
  def append(event) do
    if event.trace_id == "" do
      false
    else
      path = trace_path(event.trace_id)
      dir = Path.dirname(path)
      File.mkdir_p!(dir)
      line = Schema.to_json(event) <> "\n"

      case File.write(path, line, [:append]) do
        :ok -> true
        {:error, _} -> false
      end
    end
  end

  @doc "Append multiple events at once."
  @spec append_batch([Schema.trace_event()]) :: non_neg_integer()
  def append_batch(events) do
    events
    |> Enum.group_by(& &1.trace_id)
    |> Enum.reduce(0, fn {trace_id, trace_events}, acc ->
      path = trace_path(trace_id)
      dir = Path.dirname(path)
      File.mkdir_p!(dir)
      content = Enum.map_join(trace_events, "\n", &Schema.to_json/1) <> "\n"

      case File.write(path, content, [:append]) do
        :ok -> acc + length(trace_events)
        {:error, _} -> acc
      end
    end)
  end

  @doc "Read all events for a trace."
  @spec read(String.t()) :: [Schema.trace_event()]
  def read(trace_id) do
    path = trace_path(trace_id)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          try do
            Schema.from_json(line)
          rescue
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @doc "List all available trace IDs."
  @spec list_traces() :: [String.t()]
  def list_traces do
    dir = base_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ndjson"))
      |> Enum.map(&String.replace_suffix(&1, ".ndjson", ""))
    else
      []
    end
  end

  @doc "Delete a trace file."
  @spec delete(String.t()) :: boolean()
  def delete(trace_id) do
    path = trace_path(trace_id)

    case File.rm(path) do
      :ok -> true
      {:error, _} -> false
    end
  end

  @doc "Count events in a trace."
  @spec event_count(String.t()) :: non_neg_integer()
  def event_count(trace_id) do
    path = trace_path(trace_id)

    case File.read(path) do
      {:ok, content} ->
        content |> String.split("\n", trim: true) |> length()

      {:error, _} ->
        0
    end
  end

  defp trace_path(trace_id) do
    safe_id = trace_id |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    Path.join(base_dir(), "#{safe_id}.ndjson")
  end
end
