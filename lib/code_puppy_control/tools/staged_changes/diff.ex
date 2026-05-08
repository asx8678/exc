defmodule CodePuppyControl.Tools.StagedChanges.Diff do
  @moduledoc """
  Diff generation logic for staged changes.

  Split from staged_changes.ex to keep the main module under the 600-line cap.

  Uses file I/O cache to avoid repeated reads (matches Python
  `generate_combined_diff` caching behavior).
  """

  alias CodePuppyControl.Text.Diff
  alias CodePuppyControl.Tools.StagedChanges.StagedChange

  @doc """
  Generate a unified diff for a single staged change, with file I/O cache.

  Returns `{diff_string, updated_cache}`.
  """
  @spec gen_diff_cached(StagedChange.t(), map()) :: {String.t(), map()}
  def gen_diff_cached(%StagedChange{change_type: :create} = c, cache) do
    diff =
      Diff.unified_diff("", c.content || "",
        from_file: "/dev/null",
        to_file: "b/#{Path.basename(c.file_path)}"
      )

    {diff, cache}
  end

  def gen_diff_cached(%StagedChange{change_type: :replace} = c, cache) do
    {original_content, new_cache} = read_file_cached(c.file_path, cache)
    old_str = c.old_str || ""

    diff =
      if original_content != nil and String.contains?(original_content, old_str) do
        modified = String.replace(original_content, old_str, c.new_str || "", global: false)

        Diff.unified_diff(original_content, modified,
          from_file: "a/#{Path.basename(c.file_path)}",
          to_file: "b/#{Path.basename(c.file_path)}"
        )
      else
        ""
      end

    {diff, new_cache}
  end

  def gen_diff_cached(%StagedChange{change_type: :delete_snippet} = c, cache) do
    {original_content, new_cache} = read_file_cached(c.file_path, cache)
    snip = c.snippet || ""

    diff =
      if original_content != nil and String.contains?(original_content, snip) do
        modified = String.replace(original_content, snip, "", global: false)

        Diff.unified_diff(original_content, modified,
          from_file: "a/#{Path.basename(c.file_path)}",
          to_file: "b/#{Path.basename(c.file_path)}"
        )
      else
        ""
      end

    {diff, new_cache}
  end

  def gen_diff_cached(%StagedChange{change_type: :delete_file} = c, cache) do
    {original_content, new_cache} = read_file_cached(c.file_path, cache)

    diff =
      if original_content != nil do
        Diff.unified_diff(original_content, "",
          from_file: "a/#{Path.basename(c.file_path)}",
          to_file: "/dev/null"
        )
      else
        ""
      end

    {diff, new_cache}
  end

  def gen_diff_cached(_, cache), do: {"", cache}

  # ── Private ────────────────────────────────────────────────────────────

  # Read file content with cache to avoid repeated I/O.
  # Returns {content_or_nil, updated_cache}.
  defp read_file_cached(file_path, cache) do
    case Map.get(cache, file_path) do
      nil ->
        content =
          case File.read(file_path) do
            {:ok, data} -> data
            _ -> nil
          end

        {content, Map.put(cache, file_path, content)}

      cached ->
        {cached, cache}
    end
  end
end
