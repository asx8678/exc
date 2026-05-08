defmodule CodePuppyControl.FileOps.PathClassifier do
  @moduledoc """
  Path classifier for ignore and sensitive path detection.

  This module provides fast path classification using pre-compiled patterns:
  - Glob pattern matching for gitignore-style patterns (using Gitignore.Pattern)
  - Sensitive path detection for credentials, keys, etc.


  ## Usage

      iex> classifier = PathClassifier.new()
      iex> PathClassifier.should_ignore(classifier, "node_modules")
      true
      iex> PathClassifier.is_sensitive(classifier, "/etc/shadow")
      true
      iex> PathClassifier.classify_path(classifier, ".env")
      %{ignored: true, sensitive: true}
  """

  alias CodePuppyControl.Gitignore.Pattern

  # ============================================================================
  # PATTERN DEFINITIONS

  # ============================================================================

  # Directory-only patterns
  @dir_patterns [
    # Version control
    "**/.git/**",
    "**/.git",
    ".git/**",
    ".git",
    "**/.svn/**",
    "**/.hg/**",
    "**/.bzr/**",
    # Cross-language common patterns
    "**/target/**",
    "**/target",
    "**/build/**",
    "**/build",
    "**/dist/**",
    "**/dist",
    "**/bin/**",
    "**/vendor/**",
    "**/deps/**",
    "**/coverage/**",
    "**/doc/**",
    "**/_build/**",
    "**/.gradle/**",
    "**/project/target/**",
    "**/project/project/**",
    # Node.js / JavaScript / TypeScript
    "**/node_modules/**",
    "**/node_modules",
    "node_modules/**",
    "node_modules",
    "**/.npm/**",
    "**/.yarn/**",
    "**/.pnpm-store/**",
    "**/.nyc_output/**",
    "**/.next/**",
    "**/.nuxt/**",
    "**/out/**",
    "**/.cache/**",
    "**/.parcel-cache/**",
    "**/.vite/**",
    "**/storybook-static/**",
    "**/*.tsbuildinfo/**",
    # Python
    "**/__pycache__/**",
    "**/__pycache__",
    "__pycache__/**",
    "__pycache__",
    "**/.pytest_cache/**",
    "**/.mypy_cache/**",
    "**/.coverage",
    "**/htmlcov/**",
    "**/.tox/**",
    "**/.nox/**",
    "**/site-packages/**",
    "**/.venv/**",
    "**/.venv",
    "**/venv/**",
    "**/venv",
    "**/env/**",
    "**/ENV/**",
    "**/.env",
    "**/pip-wheel-metadata/**",
    "**/*.egg-info/**",
    "**/wheels/**",
    "**/pytest-reports/**",
    # Java (Maven, Gradle, SBT)
    "**/.classpath",
    "**/.project",
    "**/.settings/**",
    # Go
    "**/*.exe~",
    "**/*.test",
    "**/*.out",
    "**/go.work",
    "**/go.work.sum",
    # Ruby
    "**/.bundle/**",
    "**/.rvm/**",
    "**/.rbenv/**",
    "**/.yardoc/**",
    "**/rdoc/**",
    "**/.sass-cache/**",
    "**/.jekyll-cache/**",
    "**/_site/**",
    # PHP
    "**/.phpunit.result.cache",
    "**/storage/logs/**",
    "**/storage/framework/cache/**",
    "**/storage/framework/sessions/**",
    "**/storage/framework/testing/**",
    "**/storage/framework/views/**",
    "**/bootstrap/cache/**",
    # .NET / C#
    "**/obj/**",
    "**/packages/**",
    "**/.vs/**",
    "**/TestResults/**",
    "**/BenchmarkDotNet.Artifacts/**",
    # C/C++
    "**/CMakeFiles/**",
    "**/cmake_install.cmake",
    "**/.deps/**",
    "**/.libs/**",
    "**/autom4te.cache/**",
    # Perl
    "**/blib/**",
    "**/*.tmp",
    "**/*.bak",
    "**/*.old",
    "**/Makefile.old",
    "**/MANIFEST.bak",
    "**/.prove",
    # Scala
    "**/.bloop/**",
    "**/.metals/**",
    "**/.ammonite/**",
    # Elixir
    "**/.fetch",
    "**/.elixir_ls/**",
    # Swift
    "**/.build/**",
    "**/Packages/**",
    "**/*.xcodeproj/**",
    "**/*.xcworkspace/**",
    "**/DerivedData/**",
    "**/xcuserdata/**",
    "**/*.dSYM/**",
    # Dart/Flutter
    "**/.dart_tool/**",
    # Haskell
    "**/dist-newstyle/**",
    "**/.stack-work/**",
    # Erlang
    "**/ebin/**",
    "**/rel/**",
    # Common cache and temp directories
    "**/cache/**",
    "**/tmp/**",
    "**/temp/**",
    "**/.tmp/**",
    "**/.temp/**",
    "**/logs/**",
    # IDE and editor files
    "**/.idea/**",
    "**/.idea",
    "**/.vscode/**",
    "**/.vscode",
    "**/.emacs.d/auto-save-list/**",
    "**/.vim/**",
    # OS-specific files
    "**/.DS_Store",
    ".DS_Store",
    "**/Thumbs.db",
    "**/Desktop.ini",
    "**/.directory",
    # Backup files
    "**/*.backup",
    "**/*.save"
  ]

  # File patterns (binary/non-text files)
  @file_patterns [
    # Compiled/binary artifacts
    "**/*.class",
    "**/*.jar",
    "**/*.dll",
    "**/*.exe",
    "**/*.so",
    "**/*.dylib",
    "**/*.pdb",
    "**/*.o",
    "**/*.beam",
    "**/*.obj",
    "**/*.a",
    "**/*.lib",
    # Python compiled
    "**/*.pyc",
    "**/*.pyo",
    "**/*.pyd",
    # Java
    "**/*.war",
    "**/*.ear",
    "**/*.nar",
    "**/hs_err_pid*",
    # Rust
    "**/Cargo.lock",
    # Ruby
    "**/*.gem",
    "**/Gemfile.lock",
    # PHP
    "**/composer.lock",
    # .NET
    "**/*.cache",
    "**/*.user",
    "**/*.suo",
    # C/C++
    "**/CMakeCache.txt",
    "**/Makefile",
    "**/compile_commands.json",
    # Perl
    "**/Build",
    "**/Build.bat",
    "**/META.yml",
    "**/META.json",
    "**/MYMETA.*",
    # Clojure
    "**/.lein-**",
    "**/.nrepl-port",
    "**/pom.xml.asc",
    # Dart/Flutter
    "**/.packages",
    "**/pubspec.lock",
    "**/*.g.dart",
    "**/*.freezed.dart",
    "**/*.gr.dart",
    # Haskell
    "**/*.hi",
    "**/*.prof",
    "**/*.aux",
    "**/*.hp",
    "**/*.eventlog",
    "**/*.tix",
    # Erlang
    "**/*.boot",
    "**/*.plt",
    # Kotlin
    "**/*.kotlin_module",
    # Elixir
    "**/erl_crash.dump",
    "**/*.ez",
    # Log files
    "**/*.log",
    "**/*.log.*",
    "**/npm-debug.log*",
    "**/yarn-debug.log*",
    "**/yarn-error.log*",
    "**/pnpm-debug.log*",
    # IDE swap files
    "**/*.swp",
    "**/*.swo",
    "**/*~",
    "**/.#*",
    "**/#*#",
    "**/.netrwhist",
    "**/Session.vim",
    "**/.sublime-project",
    "**/.sublime-workspace",
    # Artifacts
    "**/*.orig",
    "**/*.rej",
    "**/*.patch",
    "**/*.diff",
    "**/.*.orig",
    "**/.*.rej",
    # Binary image formats
    "**/*.png",
    "**/*.jpg",
    "**/*.jpeg",
    "**/*.gif",
    "**/*.bmp",
    "**/*.tiff",
    "**/*.tif",
    "**/*.webp",
    "**/*.ico",
    "**/*.svg",
    # Binary document formats
    "**/*.pdf",
    "**/*.doc",
    "**/*.docx",
    "**/*.xls",
    "**/*.xlsx",
    "**/*.ppt",
    "**/*.pptx",
    # Archive formats
    "**/*.zip",
    "**/*.tar",
    "**/*.gz",
    "**/*.bz2",
    "**/*.xz",
    "**/*.rar",
    "**/*.7z",
    # Media files
    "**/*.mp3",
    "**/*.mp4",
    "**/*.avi",
    "**/*.mov",
    "**/*.wmv",
    "**/*.flv",
    "**/*.wav",
    "**/*.ogg",
    # Font files
    "**/*.ttf",
    "**/*.otf",
    "**/*.woff",
    "**/*.woff2",
    "**/*.eot",
    # Other binary formats
    "**/*.bin",
    "**/*.dat",
    "**/*.db",
    "**/*.sqlite",
    "**/*.sqlite3",
    # OS files
    "**/*.lnk",
    # Gradle
    "**/gradle-app.setting"
  ]

  # ============================================================================
  # SENSITIVE PATH DEFINITIONS
  # ============================================================================

  @sensitive_dir_prefixes [
    ".ssh",
    ".aws",
    ".gnupg",
    ".gcp",
    ".config/gcloud",
    ".azure",
    ".kube",
    ".docker"
  ]

  @sensitive_filenames [".env"]

  @allowed_env_patterns [".env.example", ".env.sample", ".env.template"]

  @sensitive_extensions [".pem", ".key", ".p12", ".pfx", ".keystore"]

  @sensitive_system_paths [
    "/etc/shadow",
    "/etc/sudoers",
    "/etc/passwd",
    "/etc/master.passwd",
    "/private/etc/shadow",
    "/private/etc/sudoers",
    "/private/etc/passwd",
    "/private/etc/master.passwd"
  ]

  # Home-based sensitive files
  @home_sensitive_files [
    ".netrc",
    ".pgpass",
    ".my.cnf",
    ".env",
    ".bash_history",
    ".npmrc",
    ".pypirc",
    ".gitconfig"
  ]

  defstruct [
    :dir_patterns,
    :all_patterns,
    :home_dir,
    :sensitive_dir_prefixes,
    :sensitive_exact_files,
    :sensitive_filenames,
    :sensitive_extensions
  ]

  @typedoc """
  Path classifier struct containing pre-compiled patterns.
  """
  @type t :: %__MODULE__{
          dir_patterns: [String.t()],
          all_patterns: [String.t()],
          home_dir: String.t(),
          sensitive_dir_prefixes: [String.t()],
          sensitive_exact_files: MapSet.t(String.t()),
          sensitive_filenames: MapSet.t(String.t()),
          sensitive_extensions: MapSet.t(String.t())
        }

  # Maximum symlink chain depth to prevent infinite loops
  @max_symlink_depth 20

  @doc """
  Create a new PathClassifier with all patterns pre-loaded.

  ## Examples

      iex> classifier = PathClassifier.new()
      iex> is_struct(classifier, PathClassifier)
      true
  """
  @spec new() :: t()
  def new do
    home_dir = System.user_home!()

    # Precompute sensitive directory prefixes (full paths)
    sensitive_dir_prefixes = Enum.map(@sensitive_dir_prefixes, &Path.join(home_dir, &1))

    # Build sensitive exact files set with resolved home
    home_based_files = Enum.map(@home_sensitive_files, &Path.join(home_dir, &1))

    sensitive_exact_files =
      (@sensitive_system_paths ++ home_based_files)
      |> MapSet.new()

    %__MODULE__{
      dir_patterns: @dir_patterns,
      all_patterns: @dir_patterns ++ @file_patterns,
      home_dir: home_dir,
      sensitive_dir_prefixes: sensitive_dir_prefixes,
      sensitive_exact_files: sensitive_exact_files,
      sensitive_filenames: MapSet.new(@sensitive_filenames),
      sensitive_extensions: MapSet.new(@sensitive_extensions)
    }
  end

  @doc """
  Check if a path should be ignored (matches any ignore pattern).

  ## Examples

      iex> classifier = PathClassifier.new()
      iex> PathClassifier.should_ignore(classifier, "node_modules")
      true
      iex> PathClassifier.should_ignore(classifier, "main.py")
      false
      iex> PathClassifier.should_ignore(classifier, ".git/config")
      true
  """
  @spec should_ignore(t(), String.t()) :: boolean()
  def should_ignore(%__MODULE__{} = classifier, path) when is_binary(path) do
    matches_any_pattern?(classifier, path, classifier.all_patterns)
  end

  @doc """
  Check if a directory path should be ignored (directory patterns only).

  ## Examples

      iex> classifier = PathClassifier.new()
      iex> PathClassifier.should_ignore_dir(classifier, "node_modules")
      true
      iex> PathClassifier.should_ignore_dir(classifier, "image.png")
      false
  """
  @spec should_ignore_dir(t(), String.t()) :: boolean()
  def should_ignore_dir(%__MODULE__{} = classifier, path) when is_binary(path) do
    matches_any_pattern?(classifier, path, classifier.dir_patterns)
  end

  @doc """
  Check if a path is sensitive (contains credentials, keys, etc.).

  Uses the precomputed patterns from the classifier struct for efficient lookup.

  ## Examples

      iex> classifier = PathClassifier.new()
      iex> PathClassifier.is_sensitive(classifier, "/etc/shadow")
      true
      iex> PathClassifier.is_sensitive(classifier, "~/.ssh/id_rsa")
      true
      iex> PathClassifier.is_sensitive(classifier, "main.py")
      false
      iex> PathClassifier.is_sensitive(classifier, ".env")
      true
      iex> PathClassifier.is_sensitive(classifier, ".env.example")
      false
  """
  @spec is_sensitive(t(), String.t()) :: boolean()
  def is_sensitive(%__MODULE__{} = classifier, path) when is_binary(path) do
    if path == "" do
      false
    else
      check_tilde_username_paths(path) || check_expanded_path(classifier, path)
    end
  end

  def is_sensitive(_, _), do: false

  @doc """
  Classify a path, returning a map with `ignored` and `sensitive` flags.

  ## Examples

      iex> classifier = PathClassifier.new()
      iex> PathClassifier.classify_path(classifier, "main.py")
      %{ignored: false, sensitive: false}
      iex> PathClassifier.classify_path(classifier, "node_modules")
      %{ignored: true, sensitive: false}
      iex> PathClassifier.classify_path(classifier, ".env")
      %{ignored: true, sensitive: true}
  """
  @spec classify_path(t(), String.t()) :: %{ignored: boolean(), sensitive: boolean()}
  def classify_path(%__MODULE__{} = classifier, path) when is_binary(path) do
    %{
      ignored: should_ignore(classifier, path),
      sensitive: is_sensitive(classifier, path)
    }
  end

  # ============================================================================
  # Internal: Pattern Matching
  # ============================================================================

  defp matches_any_pattern?(classifier, path, patterns) do
    # Strip leading ./ for consistent matching
    cleaned =
      if String.starts_with?(path, "./") do
        String.slice(path, 2..-1//1)
      else
        path
      end

    # Normalize: ensure there is always a directory prefix so that **
    # patterns match root-level entries.
    dotted = "./#{cleaned}"

    # Try against all patterns
    Enum.any?(patterns, fn pattern ->
      matches_pattern?(pattern, dotted, cleaned, classifier)
    end) || hidden_file_check?(cleaned)
  end

  defp matches_pattern?(pattern, dotted, cleaned, _classifier) do
    # Try normalised path (with ./ prefix)
    Pattern.pattern_match?(pattern, dotted) ||
      Pattern.pattern_match?(pattern, dotted <> "/") ||
      Pattern.pattern_match?(pattern, cleaned) ||
      matches_suffix?(pattern, cleaned)
  end

  # Try all suffixes (handles nested paths)
  defp matches_suffix?(pattern, cleaned) do
    parts = String.split(cleaned, "/")

    if length(parts) > 1 do
      1..(length(parts) - 1)
      |> Enum.any?(fn i ->
        suffix = Enum.drop(parts, i) |> Enum.join("/")

        Pattern.pattern_match?(pattern, "./#{suffix}") ||
          Pattern.pattern_match?(pattern, suffix)
      end)
    else
      false
    end
  end

  # Check for hidden files/directories (dotfiles/dotdirs)
  # This implements the "**/.*" pattern requested for Python parity.
  # Note: The bare "." (current dir) is treated as hidden here too,
  # which matches Python's **/.* behavior.
  defp hidden_file_check?(cleaned) do
    parts = String.split(cleaned, "/")

    Enum.any?(parts, fn part ->
      # Only exclude the literal ".." (parent dir navigation).
      # Names like "..hidden" or "...hidden" ARE hidden (start with dot).
      String.starts_with?(part, ".") and part != ".."
    end)
  end

  # ============================================================================
  # Internal: Sensitive Path Detection
  # ============================================================================

  # Check ~username paths for sensitive directories.
  # Returns true if sensitive, false if not a ~username path or safe.
  defp check_tilde_username_paths(path) do
    # Check if path starts with ~ followed by a username (not ~/)
    if String.starts_with?(path, "~") and String.length(path) > 1 and
         not String.starts_with?(path, "~/") do
      # This is a ~username path - check for sensitive patterns
      cond do
        # ~username/.ssh should always be sensitive (other user's SSH keys)
        String.contains?(path, "/.ssh") -> true
        # Check for ~root (root user's home directory)
        String.starts_with?(path, "~root") -> true
        # Other ~username paths that don't match specific sensitive patterns
        # are considered safe for this check
        true -> false
      end
    else
      false
    end
  end

  defp check_expanded_path(%__MODULE__{} = classifier, path) do
    # Expand ~, resolve symlinks, and normalize path
    resolved = expand_and_normalize(path)

    # Check directory prefixes (precomputed)
    sensitive_dir =
      Enum.any?(classifier.sensitive_dir_prefixes, fn prefix ->
        String.starts_with?(resolved, prefix <> "/") or resolved == prefix
      end)

    # Check macOS /private/etc
    private_etc =
      String.starts_with?(resolved, "/private/etc/") or resolved == "/private/etc"

    # Check /dev directory
    dev_check = String.starts_with?(resolved, "/dev/") or resolved == "/dev"

    # Check exact-match files (precomputed)
    exact_match = MapSet.member?(classifier.sensitive_exact_files, resolved)

    # Get basename
    basename = Path.basename(resolved)
    basename_lower = String.downcase(basename)

    # Check sensitive filenames (precomputed)
    filename_match =
      cond do
        # Check allowed env patterns first
        basename_lower in @allowed_env_patterns ->
          false

        # Check exact sensitive filenames
        MapSet.member?(classifier.sensitive_filenames, basename_lower) ->
          true

        # Check .env.* variants
        String.starts_with?(basename_lower, ".env.") ->
          basename_lower not in @allowed_env_patterns

        true ->
          false
      end

    # Check extensions (precomputed)
    ext = Path.extname(resolved) |> String.downcase()
    ext_match = MapSet.member?(classifier.sensitive_extensions, ext)

    sensitive_dir or private_etc or dev_check or exact_match or filename_match or ext_match
  end

  defp expand_and_normalize(path) do
    # Handle ~username paths (other than ~/)
    expanded =
      if String.starts_with?(path, "~") and String.length(path) > 1 and
           not String.starts_with?(path, "~/") do
        # This is a ~username path, return as-is for check_tilde_username_paths
        path
      else
        # Standard ~ expansion
        cond do
          String.starts_with?(path, "~/") ->
            home = System.user_home!()
            Path.join(home, String.slice(path, 2..-1//1))

          path == "~" ->
            System.user_home!()

          true ->
            path
        end
      end

    # Expand to absolute path
    expanded = Path.expand(expanded)

    # Resolve symlinks (security fix: )
    resolve_symlinks(expanded)
  end

  # Resolve symlinks to their targets, with loop protection
  defp resolve_symlinks(path, depth \\ 0)

  defp resolve_symlinks(path, depth) when depth > @max_symlink_depth do
    # Too many symlinks, return the path as-is (safer to check it than fail)
    path
  end

  defp resolve_symlinks(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            abs_target =
              if Path.type(target) == :relative do
                Path.join(Path.dirname(path), target) |> Path.expand()
              else
                Path.expand(target)
              end

            resolve_symlinks(abs_target, depth + 1)

          {:error, _} ->
            path
        end

      _ ->
        # Not a symlink or doesn't exist, return as-is
        path
    end
  end
end
