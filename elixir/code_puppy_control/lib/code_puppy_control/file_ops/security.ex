defmodule CodePuppyControl.FileOps.Security do
  @moduledoc """
  Security module for file operations.

  Handles sensitive path detection and path validation to prevent
  access to SSH keys, cloud credentials, and other system secrets.

  ## Security guarantees

  - **Case-insensitive matching**: All path comparisons are case-insensitive
    to handle case-insensitive filesystems (macOS HFS+/APFS).
  - **Symlink resolution**: When a path exists on disk and is a symlink,
    the resolved target is also checked for sensitivity.
  - **Extension checking**: Private key file extensions are blocked regardless
    of directory location.
  """

  # ============================================================================
  # SENSITIVE PATH DEFINITIONS (Ported from Python sensitive_paths.py)
  # ============================================================================

  @sensitive_dir_prefixes MapSet.new([
                            Path.join(System.user_home!(), ".ssh"),
                            Path.join(System.user_home!(), ".aws"),
                            Path.join(System.user_home!(), ".gnupg"),
                            Path.join(System.user_home!(), ".gcp"),
                            Path.join(System.user_home!(), ".config/gcloud"),
                            Path.join(System.user_home!(), ".azure"),
                            Path.join(System.user_home!(), ".kube"),
                            Path.join(System.user_home!(), ".docker"),
                            "/etc",
                            "/private/etc",
                            "/dev",
                            "/root",
                            "/proc",
                            "/var/log"
                          ])

  @sensitive_exact_files MapSet.new([
                           Path.join(System.user_home!(), ".netrc"),
                           Path.join(System.user_home!(), ".pgpass"),
                           Path.join(System.user_home!(), ".my.cnf"),
                           Path.join(System.user_home!(), ".env"),
                           Path.join(System.user_home!(), ".bash_history"),
                           Path.join(System.user_home!(), ".npmrc"),
                           Path.join(System.user_home!(), ".pypirc"),
                           Path.join(System.user_home!(), ".gitconfig"),
                           "/etc/shadow",
                           "/etc/sudoers",
                           "/etc/passwd",
                           "/etc/master.passwd",
                           "/private/etc/shadow",
                           "/private/etc/sudoers",
                           "/private/etc/passwd",
                           "/private/etc/master.passwd"
                         ])

  @sensitive_filenames MapSet.new([".env"])

  @allowed_env_patterns MapSet.new([".env.example", ".env.sample", ".env.template"])

  @sensitive_extensions MapSet.new([
                          ".pem",
                          ".key",
                          ".p12",
                          ".pfx",
                          ".keystore"
                        ])

  # Pre-compute lowercased versions for case-insensitive comparison
  @sensitive_dir_prefixes_lower Enum.map(@sensitive_dir_prefixes, &String.downcase/1)
  @sensitive_exact_files_lower @sensitive_exact_files
                               |> Enum.map(&String.downcase/1)
                               |> MapSet.new()

  # Maximum symlink chain depth to prevent infinite loops
  @max_symlink_depth 20

  @doc """
  Check if a path points to a sensitive file/directory.

  Performs case-insensitive matching and resolves symlinks to their
  targets before checking. Returns true if either the path itself
  or its symlink target is sensitive.

  ## Examples

      iex> Security.sensitive_path?("/home/user/.ssh/id_rsa")
      true

      iex> Security.sensitive_path?("/ETC/passwd")
      true

      iex> Security.sensitive_path?("/home/user/project/main.py")
      false
  """
  @spec sensitive_path?(String.t()) :: boolean()
  def sensitive_path?(file_path) when is_binary(file_path) do
    if file_path == "" do
      false
    else
      expanded = Path.expand(file_path)

      # Check the user-supplied path (case-insensitive)
      # Also check the symlink target if it resolves differently
      path_is_sensitive?(expanded) or
        symlink_target_is_sensitive?(expanded)
    end
  end

  def sensitive_path?(_), do: false

  @doc """
  Validate a file path before performing an operation.

  Returns {:ok, normalized_path} or {:error, reason}.
  """
  @spec validate_path(String.t(), String.t() | atom()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_path(file_path, operation) when is_binary(file_path) do
    cond do
      file_path == "" ->
        {:error, "File path cannot be empty"}

      String.contains?(file_path, "\0") ->
        {:error, "File path contains null byte"}

      sensitive_path?(file_path) ->
        {:error,
         "Access to sensitive path blocked (#{operation}): SSH keys, cloud credentials, and system secrets are never accessible."}

      true ->
        {:ok, Path.expand(file_path)}
    end
  end

  def validate_path(_, _), do: {:error, "Invalid file path"}

  # ============================================================================
  # INTERNAL: Case-insensitive path sensitivity check
  # ============================================================================

  defp path_is_sensitive?(expanded) do
    expanded_lower = String.downcase(expanded)

    # Check directory prefixes (case-insensitive)
    sensitive_dir_prefix =
      Enum.any?(@sensitive_dir_prefixes_lower, fn prefix ->
        String.starts_with?(expanded_lower, prefix <> "/") or expanded_lower == prefix
      end)

    # Check exact-match files (case-insensitive)
    sensitive_exact = MapSet.member?(@sensitive_exact_files_lower, expanded_lower)

    # Check sensitive filenames (already case-insensitive)
    basename_lower = Path.basename(expanded) |> String.downcase()

    sensitive_filename =
      cond do
        basename_lower == ".env" ->
          true

        String.starts_with?(basename_lower, ".env.") ->
          not MapSet.member?(@allowed_env_patterns, basename_lower)

        MapSet.member?(@sensitive_filenames, basename_lower) ->
          true

        true ->
          false
      end

    # Check for private key files by extension (already case-insensitive)
    ext = Path.extname(expanded) |> String.downcase()
    sensitive_ext = MapSet.member?(@sensitive_extensions, ext)

    sensitive_dir_prefix or sensitive_exact or sensitive_filename or sensitive_ext
  end

  # ============================================================================
  # INTERNAL: Symlink resolution
  # ============================================================================

  defp symlink_target_is_sensitive?(expanded) do
    case resolve_symlinks(expanded) do
      {:ok, resolved} when resolved != expanded ->
        path_is_sensitive?(resolved)

      _ ->
        false
    end
  end

  defp resolve_symlinks(path, depth \\ 0)

  defp resolve_symlinks(_path, depth) when depth > @max_symlink_depth do
    {:error, :too_many_links}
  end

  defp resolve_symlinks(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case :file.read_link(String.to_charlist(path)) do
          {:ok, target_charlist} ->
            target = List.to_string(target_charlist)

            abs_target =
              if Path.type(target) == :relative do
                Path.join(Path.dirname(path), target) |> Path.expand()
              else
                Path.expand(target)
              end

            resolve_symlinks(abs_target, depth + 1)

          {:error, _} ->
            {:ok, path}
        end

      {:ok, _} ->
        {:ok, path}

      {:error, _} ->
        # File doesn't exist on disk — can't resolve, not an error
        {:ok, path}
    end
  end
end
