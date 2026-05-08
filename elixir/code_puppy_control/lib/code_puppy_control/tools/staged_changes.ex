defmodule CodePuppyControl.Tools.StagedChanges do
  @moduledoc """
  Staged changes sandbox — diff-preview gatekeeper system.

  Ports code_puppy/staged_changes.py to Elixir with full parity:
  intercept, store, diff, preview, apply/reject, persist/restore.

  GenServer manages ETS table `:staged_changes` for concurrent reads.

  ## Security

  - All staging operations validate paths via `FileOps.Security.validate_path/2`
    to block sensitive paths (SSH keys, cloud credentials, /etc, etc.)
  - Apply operations route through `FileModifications.SafeWrite` and
    `FileModifications.FileLock` for symlink-safe atomic writes and
    per-file concurrency serialization
  - Staged tools are **slash-only** — not exposed to agents (see `Tools` module)

  ## Tool Exposure Decision (code-puppy-ctj.5)

  Staged change tool modules are intentionally **NOT** registered in the
  Tool.Registry default_modules list. They are slash-only — accessible only
  through the `/staged` command, not as agent-callable tools. This is a
  deliberate design choice: staging is a **user-review mechanism**, and
  allowing agents to invoke staged tools directly would bypass the human
  review intent. The `register_all/0` function exists for testing only.
  """

  use GenServer
  require Logger
  alias CodePuppyControl.Tool.Registry
  alias CodePuppyControl.Tools.StagedChanges.StagedChange
  alias CodePuppyControl.Tools.StagedChanges.{Applier, Diff}
  alias CodePuppyControl.FileOps.Security

  @table :staged_changes
  @stage_dir Path.join(System.tmp_dir!(), "code_puppy_staged")

  # ── Client API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enabled?, do: GenServer.call(__MODULE__, :enabled?)
  def enable, do: GenServer.call(__MODULE__, :enable)
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc """
  Toggle staging mode on/off. Returns the new enabled state.
  Matches Python `toggle()`.
  """
  def toggle, do: GenServer.call(__MODULE__, :toggle)

  @doc """
  Stage a file creation.

  Validates the file path against sensitive path rules.
  Returns `{:ok, change}` or `{:error, reason}`.
  """
  def add_create(fp, content, desc \\ ""),
    do: GenServer.call(__MODULE__, {:add_create, fp, content, desc})

  @doc """
  Stage a text replacement.

  Validates the file path against sensitive path rules.
  Returns `{:ok, change}` or `{:error, reason}`.
  """
  def add_replace(fp, old, new, desc \\ ""),
    do: GenServer.call(__MODULE__, {:add_replace, fp, old, new, desc})

  @doc """
  Stage a snippet deletion.

  Validates the file path against sensitive path rules.
  Returns `{:ok, change}` or `{:error, reason}`.
  """
  def add_delete_snippet(fp, snip, desc \\ ""),
    do: GenServer.call(__MODULE__, {:add_delete_snippet, fp, snip, desc})

  @doc """
  Stage a file deletion (DELETE_FILE change type).

  Validates the file path against sensitive path rules.
  Returns `{:ok, change}` or `{:error, reason}`.
  """
  def add_delete_file(fp, desc \\ ""),
    do: GenServer.call(__MODULE__, {:add_delete_file, fp, desc})

  @doc "Get pending staged changes (applied/rejected excluded by default).
  Pass `include_applied: true` to return all."
  def get_staged_changes(opts \\ []) do
    include_applied = Keyword.get(opts, :include_applied, false)

    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        changes =
          @table
          |> :ets.tab2list()
          |> Enum.map(fn {_, c} -> c end)

        if include_applied do
          changes |> Enum.sort_by(& &1.created_at)
        else
          changes
          |> Enum.reject(&(&1.applied or &1.rejected))
          |> Enum.sort_by(& &1.created_at)
        end
    end
  end

  @doc """
  Get staged changes for a specific file (pending only).
  Matches Python `get_changes_for_file`.
  """
  def get_changes_for_file(file_path) do
    abs_path = Path.expand(file_path)

    get_staged_changes()
    |> Enum.filter(&(&1.file_path == abs_path))
  end

  @doc """
  Count of pending staged changes.
  """
  def count, do: get_staged_changes() |> length()

  @doc """
  Check if no pending staged changes.
  Matches Python `is_empty`.
  """
  def is_empty?, do: count() == 0

  @doc """
  Remove a specific change by ID.

  Returns `true` if the change was found and removed, `false` otherwise.
  This provides boolean parity with the expected remove-change semantics.
  """
  def remove_change(id), do: GenServer.call(__MODULE__, {:remove_change, id})

  @doc """
  Clear all staged changes.
  """
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc """
  Get session ID for this sandbox.
  """
  def session_id, do: GenServer.call(__MODULE__, :session_id)

  @doc """
  Generate combined diff for all pending changes.
  Uses file I/O cache to avoid repeated reads (matches Python `generate_combined_diff`).
  """
  def get_combined_diff do
    changes = get_staged_changes()

    if changes == [] do
      ""
    else
      # Cache file contents to avoid repeated I/O (Python parity)
      {diffs, _final_cache} =
        Enum.reduce(changes, {[], %{}}, fn c, {acc, cache} ->
          {diff, new_cache} = Diff.gen_diff_cached(c, cache)

          if diff == "" do
            {acc, new_cache}
          else
            {[{c.description, c.change_id, diff} | acc], new_cache}
          end
        end)

      diffs
      |> Enum.reverse()
      |> Enum.map(fn {desc, id, d} -> "# #{desc || "change"} (#{id})\n#{d}" end)
      |> Enum.join("\n\n")
    end
  end

  @doc "Preview changes grouped by file."
  def preview_changes do
    changes = get_staged_changes()

    # Group by file_path
    grouped = Enum.group_by(changes, & &1.file_path)

    Enum.map(grouped, fn {file_path, file_changes} ->
      {diffs, _cache} =
        Enum.reduce(file_changes, {[], %{}}, fn c, {acc, cache} ->
          {diff, new_cache} = Diff.gen_diff_cached(c, cache)

          if diff == "" do
            {acc, new_cache}
          else
            {[diff | acc], new_cache}
          end
        end)

      combined = diffs |> Enum.reverse() |> Enum.join("\n\n")
      {file_path, combined}
    end)
    |> Map.new()
  end

  @doc "Get summary of staged changes (by_type, by_file, etc.)."
  def get_summary do
    changes = get_staged_changes()

    by_type =
      Enum.reduce(changes, %{}, fn c, acc ->
        key = Atom.to_string(c.change_type)
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    by_file =
      Enum.reduce(changes, %{}, fn c, acc ->
        Map.update(acc, c.file_path, 1, &(&1 + 1))
      end)

    %{
      total: length(changes),
      by_type: by_type,
      by_file: map_size(by_file),
      files: Map.keys(by_file),
      enabled: GenServer.call(__MODULE__, :enabled?),
      session_id: GenServer.call(__MODULE__, :session_id)
    }
  end

  @doc "Save staged changes to disk (atomic write). Fixes Python triple-write bug."
  def save_to_disk do
    GenServer.call(__MODULE__, :save_to_disk)
  end

  @doc "Load staged changes from disk. Returns `true` on success, `false` on failure."
  def load_from_disk(session_id \\ nil) do
    GenServer.call(__MODULE__, {:load_from_disk, session_id})
  end

  def apply_all, do: GenServer.call(__MODULE__, :apply_all, 30_000)
  def reject_all, do: GenServer.call(__MODULE__, :reject_all)

  @doc """
  Register all staged changes tool modules with the Tool Registry.

  **NOTE:** This function is for testing only. Staged change tools are
  **slash-only** — not exposed to agents. See module doc for rationale.
  """
  def register_all do
    alias CodePuppyControl.Tools.StagedChanges.Tools
    alias CodePuppyControl.Tool.Registry

    [
      Tools.StageCreateTool,
      Tools.StageReplaceTool,
      Tools.StageDeleteSnippetTool,
      Tools.StageDeleteFileTool,
      Tools.GetStagedDiffTool,
      Tools.ApplyStagedTool,
      Tools.RejectStagedTool
    ]
    |> Enum.reduce({:ok, 0}, fn m, {:ok, acc} ->
      case Registry.register(m) do
        :ok -> {:ok, acc + 1}
        _ -> {:ok, acc}
      end
    end)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      try do
        :ets.new(@table, [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> @table
      end

    session_id = generate_session_id()
    ensure_stage_dir()

    {:ok, %{table: table, enabled: false, session_id: session_id}}
  end

  @impl true
  def handle_call(:enabled?, _, s), do: {:reply, s.enabled, s}
  @impl true
  def handle_call(:enable, _, s), do: {:reply, :ok, %{s | enabled: true}}
  @impl true
  def handle_call(:disable, _, s), do: {:reply, :ok, %{s | enabled: false}}

  @impl true
  def handle_call(:toggle, _, s) do
    new_enabled = not s.enabled
    {:reply, new_enabled, %{s | enabled: new_enabled}}
  end

  @impl true
  def handle_call(:session_id, _, s), do: {:reply, s.session_id, s}

  @impl true
  def handle_call({:add_create, fp, content, desc}, _, s) do
    with {:ok, _} <- validate_staged_path(fp, "stage_create") do
      c = mk(:create, fp, content: content, description: desc)
      :ets.insert(@table, {c.change_id, c})
      {:reply, {:ok, c}, s}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call({:add_replace, fp, old, new, desc}, _, s) do
    with {:ok, _} <- validate_staged_path(fp, "stage_replace") do
      c = mk(:replace, fp, old_str: old, new_str: new, description: desc)
      :ets.insert(@table, {c.change_id, c})
      {:reply, {:ok, c}, s}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call({:add_delete_snippet, fp, snip, desc}, _, s) do
    with {:ok, _} <- validate_staged_path(fp, "stage_delete_snippet") do
      c = mk(:delete_snippet, fp, snippet: snip, description: desc)
      :ets.insert(@table, {c.change_id, c})
      {:reply, {:ok, c}, s}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call({:add_delete_file, fp, desc}, _, s) do
    with {:ok, _} <- validate_staged_path(fp, "stage_delete_file") do
      c = mk(:delete_file, fp, description: desc)
      :ets.insert(@table, {c.change_id, c})
      {:reply, {:ok, c}, s}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call({:remove_change, id}, _, s) do
    # Return boolean: true if found and deleted, false if not found
    case :ets.lookup(@table, id) do
      [{^id, _}] ->
        :ets.delete(@table, id)
        {:reply, true, s}

      [] ->
        {:reply, false, s}
    end
  end

  @impl true
  def handle_call(:clear, _, s) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, s}
  end

  @impl true
  def handle_call(:reject_all, _, s) do
    changes = get_staged_changes()
    for c <- changes, do: :ets.insert(@table, {c.change_id, %{c | rejected: true}})
    {:reply, length(changes), s}
  end

  @impl true
  def handle_call(:apply_all, _, s) do
    changes = get_staged_changes()

    if changes == [] do
      {:reply, {:ok, 0}, s}
    else
      result =
        Enum.reduce_while(changes, {:ok, 0}, fn c, {:ok, acc} ->
          case Applier.apply_change(c) do
            :ok ->
              :ets.insert(@table, {c.change_id, %{c | applied: true}})
              {:cont, {:ok, acc + 1}}

            {:error, r} ->
              {:halt, {:error, "Failed #{c.change_id}: #{r}"}}
          end
        end)

      {:reply, result, s}
    end
  end

  @impl true
  def handle_call(:save_to_disk, _, s) do
    ensure_stage_dir()
    save_path = Path.join(@stage_dir, "#{s.session_id}.json")
    tmp_path = Path.join(@stage_dir, "#{s.session_id}.json.tmp")

    data = %{
      "session_id" => s.session_id,
      "enabled" => s.enabled,
      "changes" => get_staged_changes(include_applied: true) |> Enum.map(&StagedChange.to_map/1),
      "saved_at" => System.system_time(:second)
    }

    # Atomic write: write to temp file first, then rename
    # Fixes the Python triple-write bug where data block was repeated 3x
    case File.write(tmp_path, Jason.encode!(data, pretty: true)) do
      :ok ->
        case File.rename(tmp_path, save_path) do
          :ok ->
            Logger.info("Saved staged changes to #{save_path}")
            {:reply, {:ok, save_path}, s}

          {:error, reason} ->
            File.rm(tmp_path)
            {:reply, {:error, "Rename failed: #{reason}"}, s}
        end

      {:error, reason} ->
        {:reply, {:error, "Write failed: #{reason}"}, s}
    end
  end

  @impl true
  def handle_call({:load_from_disk, nil}, _, s) do
    handle_call({:load_from_disk, s.session_id}, nil, s)
  end

  @impl true
  def handle_call({:load_from_disk, session_id}, _, s) do
    load_path = Path.join(@stage_dir, "#{session_id}.json")

    case File.read(load_path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, data} ->
            # Robust deserialization: validate "changes" is a list
            raw_changes = Map.get(data, "changes", [])

            {loaded_changes, skipped} =
              if is_list(raw_changes) do
                Enum.reduce(raw_changes, {[], 0}, fn entry, {acc, skip_count} ->
                  case StagedChange.from_map(entry) do
                    {:ok, c} ->
                      {[c | acc], skip_count}

                    {:error, reason} ->
                      Logger.warning("Skipping malformed staged change: #{reason}")
                      {acc, skip_count + 1}
                  end
                end)
              else
                Logger.warning(
                  "Ignoring malformed 'changes' field (expected list, got #{inspect(raw_changes)}), loading 0 changes"
                )

                {[], 0}
              end

            loaded_changes = Enum.reverse(loaded_changes)

            if skipped > 0 do
              Logger.warning("Skipped #{skipped} malformed staged changes during load")
            end

            # Rebuild ETS from loaded changes
            :ets.delete_all_objects(@table)

            for c <- loaded_changes do
              :ets.insert(@table, {c.change_id, c})
            end

            new_session_id = Map.get(data, "session_id", session_id)
            new_enabled = Map.get(data, "enabled", false)

            Logger.info("Loaded #{length(loaded_changes)} staged changes from #{load_path}")

            {:reply, true, %{s | session_id: new_session_id, enabled: new_enabled}}

          {:error, reason} ->
            Logger.error("Failed to parse staged changes JSON: #{inspect(reason)}")
            {:reply, false, s}
        end

      {:error, _} ->
        {:reply, false, s}
    end
  end

  @impl true
  def handle_info(_, s), do: {:noreply, s}

  # ── Private helpers ──────────────────────────────────────────────────────

  defp generate_session_id do
    :crypto.hash(:sha256, :erlang.term_to_binary(System.system_time(:millisecond)))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp ensure_stage_dir do
    File.mkdir_p!(@stage_dir)
  end

  defp validate_staged_path(fp, operation) do
    Security.validate_path(fp, operation)
  end

  defp mk(type, fp, opts) do
    desc = if (d = opts[:description]) != nil and d != "", do: d, else: default_desc(type, fp)

    StagedChange.new(
      change_id: id(),
      change_type: type,
      file_path: Path.expand(fp),
      content: opts[:content],
      old_str: opts[:old_str],
      new_str: opts[:new_str],
      snippet: opts[:snippet],
      description: desc,
      # Use microsecond timestamp for stable insertion-order sorting
      created_at: System.system_time(:microsecond),
      applied: false,
      rejected: false
    )
  end

  defp default_desc(:create, fp), do: "Create #{Path.basename(fp)}"
  defp default_desc(:replace, fp), do: "Replace in #{Path.basename(fp)}"
  defp default_desc(:delete_snippet, fp), do: "Delete from #{Path.basename(fp)}"
  defp default_desc(:delete_file, fp), do: "Delete #{Path.basename(fp)}"
  defp default_desc(_, fp), do: "Change #{Path.basename(fp)}"

  defp id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
