defmodule CodePuppyControl.VersionChecker do
  @moduledoc """
  Version checking utilities for Code Puppy (Elixir).

  Checks for newer releases via the GitHub Releases API, caches results
  for 24 hours, and emits `version_check` events through the EventBus.

  ## Integration points

  - **HTTP client:** `CodePuppyControl.HttpClient.get/2` (Finch-based)
  - **Cache path:** `CodePuppyControl.Config.Paths.cache_dir()/version_cache.json`
  - **Event broadcasting:** `CodePuppyControl.EventBus.broadcast_event/2`
  - **Current version:** `Application.spec(:code_puppy_control, :vsn)`

  ## Startup wiring (not in this module)

  To wire into application startup later:

      CodePuppyControl.VersionChecker.default_version_mismatch_behavior()

  This should be called once after the supervision tree is up, typically
  from a startup callback or the CLI REPL entry point.
  """

  require Logger

  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.EventBus
  alias CodePuppyControl.HttpClient

  @cache_ttl_hours 24
  @cache_filename "version_cache.json"
  @default_github_repo "asx8678/code_puppy"
  @default_timeout_ms 3_000
  @unknown_version "0.0.0-unknown"

  # ===========================================================================
  # Pure helpers
  # ===========================================================================

  @doc """
  Strip a leading `"v"` from a version string.

  ## Examples

      iex> CodePuppyControl.VersionChecker.normalize_version("v1.2.3")
      "1.2.3"

      iex> CodePuppyControl.VersionChecker.normalize_version("1.2.3")
      "1.2.3"

      iex> CodePuppyControl.VersionChecker.normalize_version(nil)
      nil

      iex> CodePuppyControl.VersionChecker.normalize_version("")
      ""
  """
  @spec normalize_version(String.t() | nil) :: String.t() | nil
  def normalize_version(nil), do: nil
  def normalize_version(v), do: String.trim_leading(v, "v")

  @doc """
  Returns `true` if `latest` is strictly newer than `current`.

  Uses integer tuple comparison so that `"1.10.0" > "1.9.0"` works correctly.
  Returns `false` if either version cannot be parsed as a dotted-integer tuple.
  """
  @spec version_is_newer(String.t() | nil, String.t() | nil) :: boolean()
  def version_is_newer(latest, current) do
    latest_tuple = latest |> normalize_version() |> version_tuple()
    current_tuple = current |> normalize_version() |> version_tuple()

    case {latest_tuple, current_tuple} do
      {lt, ct} when lt != nil and ct != nil -> lt > ct
      _ -> false
    end
  end

  @doc """
  Returns `true` if `current` and `latest` represent the same version.

  Tries integer tuple comparison first. Falls back to string equality
  (after normalization) if either side cannot be parsed.
  """
  @spec versions_are_equal(String.t() | nil, String.t() | nil) :: boolean()
  def versions_are_equal(current, latest) do
    current_norm = normalize_version(current)
    latest_norm = normalize_version(latest)

    current_tuple = version_tuple(current_norm)
    latest_tuple = version_tuple(latest_norm)

    case {current_tuple, latest_tuple} do
      {ct, lt} when ct != nil and lt != nil -> ct == lt
      _ -> current_norm == latest_norm
    end
  end

  @doc """
  Returns the current version of the running application.
  """
  @spec current_version() :: String.t()
  def current_version do
    to_string(Application.spec(:code_puppy_control, :vsn))
  end

  # ===========================================================================
  # Cache helpers
  # ===========================================================================

  @doc false
  @spec cache_path() :: String.t()
  def cache_path do
    Path.join(Paths.cache_dir(), @cache_filename)
  end

  @doc false
  @spec read_cache() :: map() | nil
  def read_cache do
    path = cache_path()

    with {:exists, true} <- {:exists, File.exists?(path)},
         {:read, {:ok, raw}} <- {:read, File.read(path)},
         {:decode, {:ok, data}} <- {:decode, Jason.decode(raw)},
         {:checked_at, {:ok, checked_at, _offset}} <-
           {:checked_at, DateTime.from_iso8601(data["checked_at"] || "")},
         age_hours = DateTime.diff(DateTime.utc_now(), checked_at, :second) / 3600,
         true <- age_hours <= @cache_ttl_hours do
      Logger.debug("Version cache hit: #{data["version"]}")
      data
    else
      {:exists, false} ->
        nil

      _other ->
        Logger.debug("Failed to read version cache")
        nil
    end
  end

  @doc false
  @spec write_cache(String.t()) :: :ok
  def write_cache(version) do
    path = cache_path()

    try do
      File.mkdir_p!(Path.dirname(path))

      cache_data = %{
        "version" => version,
        "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(path, Jason.encode!(cache_data))
      Logger.debug("Version cache written: #{version}")
    rescue
      e ->
        Logger.debug("Failed to write version cache: #{Exception.message(e)}")
    end

    :ok
  end

  # ===========================================================================
  # Fetching
  # ===========================================================================

  @doc """
  Fetch the latest release version from GitHub, cache-first.

  Returns `{:ok, version_string}` or `{:error, reason}`.

  ## Options

    * `:base_url` — Override the GitHub API URL (for testing with a local HTTP server).
    * `:timeout` — HTTP timeout in milliseconds (default: 3000).
  """
  @spec fetch_latest_version(keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_latest_version(opts \\ []) do
    case read_cache() do
      %{"version" => version} when is_binary(version) ->
        {:ok, version}

      nil ->
        fetch_from_github(opts)
    end
  end

  defp fetch_from_github(opts) do
    url = github_releases_url(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    headers = github_headers()

    case HttpClient.get(url, headers: headers, timeout: timeout, retries: 0) do
      {:ok, %{status: 403} = resp} ->
        if rate_limited?(resp) do
          Logger.debug("GitHub API rate limited")
          {:error, :rate_limited}
        else
          Logger.debug("GitHub API returned 403")
          {:error, :forbidden}
        end

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"tag_name" => tag}} ->
            version = normalize_version(tag)
            write_cache(version)
            {:ok, version}

          {:ok, _other} ->
            Logger.debug("GitHub response missing tag_name")
            {:error, :no_tag_name}

          {:error, _} ->
            Logger.debug("GitHub response not valid JSON")
            {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        Logger.debug("GitHub API returned status #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.debug("GitHub API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp github_releases_url(opts) do
    case Keyword.get(opts, :base_url) do
      nil ->
        owner_repo = System.get_env("PUP_EX_GITHUB_REPO", @default_github_repo)
        "https://api.github.com/repos/#{owner_repo}/releases/latest"

      url ->
        url
    end
  end

  defp github_headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "code-puppy-elixir/" <> current_version()},
      {"x-github-api-version", "2022-11-28"}
    ]
  end

  defp rate_limited?(%{headers: headers}) do
    case List.keyfind(headers, "x-ratelimit-remaining", 0) do
      {"x-ratelimit-remaining", "0"} -> true
      _ -> false
    end
  end

  defp rate_limited?(_), do: false

  # ===========================================================================
  # Background check
  # ===========================================================================

  @doc """
  Fire-and-forget background version check.

  Fetches the latest version from GitHub (bypassing cache), then emits
  a `version_check` event via the EventBus.

  Returns `{:ok, pid}` from `Task.start/1`.

  ## Note

  Uses `Task.start/1` instead of `Task.Supervisor.async_nolink/2` because
  no `CodePuppyControl.TaskSupervisor` exists in the application supervision
  tree yet. When one is added, this should be updated to use the supervised
  variant for proper crash isolation.
  """
  @spec check_version_background(String.t() | nil) :: {:ok, pid()}
  def check_version_background(current \\ nil) do
    current = resolve_current(current)

    Task.start(fn ->
      case fetch_from_github([]) do
        {:ok, latest} ->
          emit_version_event(current, latest)

        {:error, reason} ->
          Logger.debug("Background version check failed: #{inspect(reason)}")
          :ok
      end
    end)
  end

  # ===========================================================================
  # Main entry point
  # ===========================================================================

  @doc """
  Cache-first version check that never blocks on network.

  If the cache is fresh (≤ 24 h), emits a `version_check` event immediately
  with the cached latest version. If the cache is stale or missing, emits a
  "current only" event and returns — the caller should kick off a background
  check via `check_version_background/1`.
  """
  @spec default_version_mismatch_behavior(String.t() | nil) :: :ok
  def default_version_mismatch_behavior(current \\ nil) do
    current = resolve_current(current)

    case read_cache() do
      %{"version" => latest} when is_binary(latest) ->
        emit_version_event(current, latest)

      nil ->
        # Cache miss — emit "current only" event, return without blocking
        event = %{
          type: "version_check",
          current_version: current,
          latest_version: current,
          update_available: false,
          release_url: nil,
          timestamp: DateTime.utc_now()
        }

        EventBus.broadcast_event(event, store: false)
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp version_tuple(nil), do: nil

  defp version_tuple(version_str) when is_binary(version_str) do
    parts = String.split(version_str, ".")

    try do
      int_parts = Enum.map(parts, &String.to_integer/1)
      List.to_tuple(int_parts)
    rescue
      ArgumentError -> nil
    end
  end

  defp version_tuple(_), do: nil

  defp resolve_current(nil) do
    Logger.warning("Could not detect current version, using fallback")
    @unknown_version
  end

  defp resolve_current(current), do: current

  defp emit_version_event(current, latest) do
    update_available = version_is_newer(latest, current)

    release_url =
      if update_available do
        owner_repo = System.get_env("PUP_EX_GITHUB_REPO", @default_github_repo)
        "https://github.com/#{owner_repo}/releases/tag/v#{latest}"
      else
        nil
      end

    event = %{
      type: "version_check",
      current_version: current,
      latest_version: latest,
      update_available: update_available,
      release_url: release_url,
      timestamp: DateTime.utc_now()
    }

    EventBus.broadcast_event(event, store: false)
  end
end
