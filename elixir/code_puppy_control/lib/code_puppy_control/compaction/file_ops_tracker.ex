defmodule CodePuppyControl.Compaction.FileOpsTracker do
  @moduledoc """
  Tracks file operations across message history for compaction summaries.

  Extracts read/write/edit tool calls from messages and provides priority
  scoring for compaction decisions. Files that were re-read or re-modified
  later in history are safe to prune from earlier context.

  Port of `code_puppy/compaction/file_ops_tracker.py`.

  ## Usage

      tracker = FileOpsTracker.new()
      tracker = FileOpsTracker.track_tool_call(tracker, "read_file", %{"file_path" => "lib/foo.ex"})
      tracker = FileOpsTracker.track_tool_call(tracker, "create_file", %{"file_path" => "lib/bar.ex"})
      scores = FileOpsTracker.priority_scores(tracker)
  """

  @type t :: %__MODULE__{
          read: MapSet.t(String.t()),
          written: MapSet.t(String.t()),
          edited: MapSet.t(String.t())
        }

  defstruct read: MapSet.new(),
            written: MapSet.new(),
            edited: MapSet.new()

  # Tool name -> operation type classification
  @read_tools MapSet.new(~w(read_file read))
  @write_tools MapSet.new(~w(write_to_file write_file create_file write))
  @edit_tools MapSet.new(~w(replace_in_file edit_file edit apply_patch delete_snippet_from_file))
  @path_keys ["file_path", "path"]

  @doc """
  Creates a new empty tracker.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Track a tool call by name and args.

  Classifies the operation as read/write/edit based on tool name,
  extracting the file path from common argument keys.

  Returns the updated tracker.
  """
  @spec track_tool_call(t(), String.t(), map()) :: t()
  def track_tool_call(%__MODULE__{} = tracker, tool_name, args) when is_map(args) do
    path = extract_path(args)

    if path do
      classify_and_add(tracker, tool_name, path)
    else
      tracker
    end
  end

  def track_tool_call(%__MODULE__{} = tracker, _tool_name, _args), do: tracker

  @doc """
  Track file operations from a single message.

  Scans the message's parts for tool-call parts and tracks them.
  Accepts both atom-keyed and string-keyed message maps.
  """
  @spec track_message(t(), map()) :: t()
  def track_message(%__MODULE__{} = tracker, message) do
    parts = get_field(message, :parts) || []

    Enum.reduce(parts, tracker, fn part, acc ->
      kind = get_field(part, :part_kind)

      if kind == "tool-call" do
        tool_name = get_field(part, :tool_name) || ""
        args = get_field(part, :args) || %{}
        track_tool_call(acc, tool_name, args)
      else
        acc
      end
    end)
  end

  @doc """
  Extract file operations from a list of messages.

  Returns a tracker with all extracted operations accumulated.
  """
  @spec extract_from_messages([map()]) :: t()
  def extract_from_messages(messages) when is_list(messages) do
    Enum.reduce(messages, new(), fn msg, tracker -> track_message(tracker, msg) end)
  end

  @doc """
  Merge another tracker's operations into this one.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      read: MapSet.union(a.read, b.read),
      written: MapSet.union(a.written, b.written),
      edited: MapSet.union(a.edited, b.edited)
    }
  end

  @doc """
  Returns sorted list of read files.
  """
  @spec read_files(t()) :: [String.t()]
  def read_files(%__MODULE__{} = tracker), do: tracker.read |> MapSet.to_list() |> Enum.sort()

  @doc """
  Returns sorted list of modified files (written + edited, deduplicated).
  """
  @spec modified_files(t()) :: [String.t()]
  def modified_files(%__MODULE__{} = tracker) do
    MapSet.union(tracker.written, tracker.edited) |> MapSet.to_list() |> Enum.sort()
  end

  @doc """
  Whether any operations have been tracked.
  """
  @spec has_ops?(t()) :: boolean()
  def has_ops?(%__MODULE__{} = tracker) do
    not Enum.empty?(tracker.read) or
      not Enum.empty?(tracker.written) or
      not Enum.empty?(tracker.edited)
  end

  @doc """
  Compute priority scores for tracked files.

  Higher score = safer to prune from history (file was re-accessed later).

  Scoring formula:
  - Base: 0.5
  - +0.5 if file was modified
  - +0.3 if file was written (stronger than just edited)

  Returns `%{file_path => float_score}`.
  """
  @spec priority_scores(t(), non_neg_integer()) :: %{String.t() => float()}
  def priority_scores(%__MODULE__{} = tracker, _total_messages \\ 100) do
    all_files =
      MapSet.union(tracker.read, MapSet.union(tracker.written, tracker.edited))
      |> MapSet.to_list()

    Map.new(all_files, fn file ->
      modified? = MapSet.member?(tracker.written, file) or MapSet.member?(tracker.edited, file)
      written? = MapSet.member?(tracker.written, file)

      base = 0.5
      score = if modified?, do: base + 0.5, else: base
      score = if written?, do: score + 0.3, else: score

      {file, min(score, 1.0)}
    end)
  end

  @doc """
  Format tracked file operations as XML tags for compaction summaries.

  Produces XML like:

      <read-files>
      - src/main.py
      - src/utils.py
      </read-files>
      <modified-files>
      - src/config.py
      </modified-files>

  Returns empty string if no operations were tracked.
  """
  @spec format_xml(t()) :: String.t()
  def format_xml(%__MODULE__{} = tracker) do
    if not has_ops?(tracker) do
      ""
    else
      parts = []

      rf = read_files(tracker)

      parts =
        if rf != [] do
          lines = Enum.map_join(rf, "\n", &"- #{&1}")
          ["<read-files>\n#{lines}\n</read-files>" | parts]
        else
          parts
        end

      mf = modified_files(tracker)

      parts =
        if mf != [] do
          lines = Enum.map_join(mf, "\n", &"- #{&1}")
          ["<modified-files>\n#{lines}\n</modified-files>" | parts]
        else
          parts
        end

      Enum.join(Enum.reverse(parts), "\n")
    end
  end

  # --- Private helpers ---

  defp classify_and_add(tracker, tool_name, path) do
    cond do
      MapSet.member?(@read_tools, tool_name) ->
        %{tracker | read: MapSet.put(tracker.read, path)}

      MapSet.member?(@write_tools, tool_name) ->
        %{tracker | written: MapSet.put(tracker.written, path)}

      MapSet.member?(@edit_tools, tool_name) ->
        %{tracker | edited: MapSet.put(tracker.edited, path)}

      true ->
        tracker
    end
  end

  defp extract_path(args) do
    Enum.find_value(@path_keys, fn key ->
      case Map.get(args, key) do
        path when is_binary(path) and path != "" -> path
        _ -> nil
      end
    end)
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      val -> val
    end
  end
end
