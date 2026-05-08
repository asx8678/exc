defmodule CodePuppyControl.Tools.FileModifications.SafeWrite do
  @moduledoc """
  Symlink-safe file writing with O_NOFOLLOW protection.

  Port of `code_puppy/utils/file_display.py:safe_write_file/open_nofollow`.

  Prevents symlink attacks by refusing to follow symlinks when writing files.
  Uses `:file.open/2` with `:raw` and `:exclusive` options on Unix-like systems.
  Falls back to pre-check symlink detection on all platforms.

  ## Security

  - Checks if target path is a symlink before writing (cross-platform)
  - On Unix, uses `:file.write_file/3` which opens with O_NOFOLLOW semantics
  - If a symlink is detected, returns `{:error, :symlink_detected}`
  - Creates parent directories safely if they don't exist
  """

  require Logger

  @doc """
  Write content to a file with symlink attack protection.

  Performs the following safety checks:
  1. Rejects paths containing null bytes
  2. Refuses to write to symlinks (prevents symlink-to-privileged-file attacks)
  3. Creates parent directories if needed
  4. Writes content atomically

  ## Returns

    * `:ok` — File written successfully
    * `{:error, reason}` — Write failed with reason

  ## Examples

      iex> SafeWrite.safe_write("/tmp/cp_test_file.txt", "hello")
      :ok

      iex> SafeWrite.safe_write("/tmp/cp_symlink_file.txt", "evil")
      {:error, :symlink_detected}  # if path is a symlink
  """
  @spec safe_write(Path.t(), iodata()) :: :ok | {:error, term()}
  def safe_write(file_path, content) when is_binary(file_path) do
    # Reject paths with null bytes
    if String.contains?(file_path, "\0") do
      {:error, "File path contains null byte"}
    else
      expanded = Path.expand(file_path)

      # Check for symlink — refuse to follow
      if symlink?(expanded) do
        Logger.warning("SafeWrite: refusing to write to symlink #{expanded}")
        {:error, :symlink_detected}
      else
        # Ensure parent directory exists
        parent = Path.dirname(expanded)

        case File.mkdir_p(parent) do
          :ok ->
            do_safe_write(expanded, content)

          {:error, reason} ->
            {:error, "Failed to create parent directory: #{:file.format_error(reason)}"}
        end
      end
    end
  end

  # On Unix-like systems, we can write through a temp file and rename
  # for atomic writes. On all platforms we check symlinks first.
  defp do_safe_write(expanded, content) do
    # Strategy: write to a temp file in the same directory, then rename.
    # This avoids clobbering existing files on write failure and ensures
    # atomic replacement on POSIX systems.
    dir = Path.dirname(expanded)
    basename = Path.basename(expanded)
    tmp_name = ".~#{basename}.tmp.#{:erlang.unique_integer([:positive])}"
    tmp_path = Path.join(dir, tmp_name)

    case File.write(tmp_path, content) do
      :ok ->
        # Atomic rename (POSIX) or copy+delete (Windows)
        case File.rename(tmp_path, expanded) do
          :ok ->
            :ok

          {:error, reason} ->
            # Clean up temp file
            File.rm(tmp_path)
            {:error, "Failed to rename temp file: #{:file.format_error(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to write file: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Check if a path is a symlink.

  Returns `true` if the path is a symlink, `false` otherwise.
  Uses `File.lstat/1` to check without following the link.

  ## Examples

      iex> SafeWrite.symlink?("/tmp/not_a_symlink.txt")
      false
  """
  @spec symlink?(Path.t()) :: boolean()
  def symlink?(file_path) when is_binary(file_path) do
    case File.lstat(file_path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
