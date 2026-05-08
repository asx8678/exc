defmodule CodePuppyControl.Tools.StagedChanges.Applier do
  @moduledoc """
  Apply logic for staged changes.

  Split from staged_changes.ex to keep the main module under the 600-line cap.

  ## Security

  All apply operations route through SafeWrite and FileLock for
  symlink-safe atomic writes and per-file concurrency serialization.
  Delete-file apply revalidates paths, refuses directories/symlinks,
  and uses FileLock — parity with the DeleteFile tool.
  """

  require Logger

  alias CodePuppyControl.FileOps.Security
  alias CodePuppyControl.Text.ReplaceEngine
  alias CodePuppyControl.Tools.StagedChanges.StagedChange
  alias CodePuppyControl.Tools.FileModifications.{SafeWrite, FileLock}

  @doc """
  Apply a single staged change to disk.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec apply_change(StagedChange.t()) :: :ok | {:error, String.t()}
  def apply_change(%StagedChange{change_type: :create} = c) do
    FileLock.with_lock(c.file_path, fn ->
      SafeWrite.safe_write(c.file_path, c.content || "")
    end)
    |> normalize_safe_write_result()
  end

  def apply_change(%StagedChange{change_type: :replace} = c) do
    FileLock.with_lock(c.file_path, fn ->
      case File.read(c.file_path) do
        {:ok, content} ->
          case ReplaceEngine.replace_in_content(content, [{c.old_str || "", c.new_str || ""}]) do
            {:ok, %{modified: m}} -> SafeWrite.safe_write(c.file_path, m)
            {:error, %{reason: r}} -> {:error, r}
          end

        e ->
          e
      end
    end)
    |> normalize_result()
  end

  def apply_change(%StagedChange{change_type: :delete_snippet} = c) do
    FileLock.with_lock(c.file_path, fn ->
      case File.read(c.file_path) do
        {:ok, content} ->
          snip = c.snippet || ""

          if String.contains?(content, snip),
            do:
              SafeWrite.safe_write(c.file_path, String.replace(content, snip, "", global: false)),
            else: {:error, "Snippet not found"}

        e ->
          e
      end
    end)
    |> normalize_result()
  end

  def apply_change(%StagedChange{change_type: :delete_file} = c) do
    # Parity with DeleteFile tool: revalidate path, refuse dirs/symlinks,
    # use FileLock, normalized errors
    with {:ok, expanded_path} <- Security.validate_path(c.file_path, "delete") do
      FileLock.with_lock(expanded_path, fn ->
        do_safe_delete(expanded_path)
      end)
      |> normalize_result()
    else
      {:error, reason} -> {:error, "Path validation failed: #{reason}"}
    end
  end

  def apply_change(_), do: {:error, "Unsupported change type"}

  # ── Private: safe delete (parity with DeleteFile tool) ──────────────────

  defp do_safe_delete(file_path) do
    cond do
      not File.exists?(file_path) ->
        :ok

      File.dir?(file_path) ->
        {:error, "Cannot delete directory — only files are supported"}

      SafeWrite.symlink?(file_path) ->
        {:error, "Refusing to delete symlink (security: symlink attack prevention)"}

      true ->
        case File.rm(file_path) do
          :ok -> :ok
          {:error, reason} -> {:error, "Delete failed: #{:file.format_error(reason)}"}
        end
    end
  end

  # ── Normalize helpers ──────────────────────────────────────────────────

  defp normalize_safe_write_result(:ok), do: :ok

  defp normalize_safe_write_result({:error, reason}),
    do: {:error, "SafeWrite failed: #{reason}"}

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _}), do: :ok

  defp normalize_result({:error, reason}) when is_binary(reason),
    do: {:error, reason}

  defp normalize_result({:error, %_{__exception__: true} = exception}),
    do: {:error, Exception.message(exception)}

  defp normalize_result({:error, reason}),
    do: {:error, inspect(reason)}
end
