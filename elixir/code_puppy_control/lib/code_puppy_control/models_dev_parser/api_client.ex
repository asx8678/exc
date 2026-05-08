defmodule CodePuppyControl.ModelsDevParser.ApiClient do
  @moduledoc """
  HTTP client for fetching models.dev API data.

  Handles API requests, caching, and proper error handling with
  consistent 2-tuple return types: {:ok, data} or {:error, reason}.
  """

  require Logger

  @models_dev_api_url "https://models.dev/api.json"
  @cache_ttl_seconds 300

  @doc """
  Fetches model data from the live API with caching support.

  Returns:
  - `{:ok, data}` - Successfully fetched and decoded data
  - `{:error, reason}` - Failed to fetch or decode
  """
  @spec fetch_from_api(map()) :: {:ok, map()} | {:error, term()}
  def fetch_from_api(%{cached_data: data, cache_time: time} = state)
      when not is_nil(data) and not is_nil(time) do
    now = System.monotonic_time(:second)
    age = now - time

    if age < @cache_ttl_seconds do
      Logger.info("Using cached models data (#{age}s old)")
      {:ok, data}
    else
      do_fetch_from_api(state)
    end
  end

  def fetch_from_api(state) do
    do_fetch_from_api(state)
  end

  @doc """
  Performs the actual HTTP fetch from models.dev API.

  Updates cache in state but returns just the data tuple.

  Returns:
  - `{:ok, data}` - Successful fetch with valid JSON
  - `{:error, reason}` - HTTP error, decode error, or invalid response
  """
  @spec do_fetch_from_api(map()) :: {:ok, map()} | {:error, term()}
  def do_fetch_from_api(state) do
    # Allow dependency injection for testing via state
    http_client = Map.get(state, :http_client, CodePuppyControl.HttpClient)

    case http_client.get(@models_dev_api_url, timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) and map_size(data) > 0 ->
            now = System.monotonic_time(:second)
            # Update cache in state for tracking
            _new_state = %{state | cached_data: data, cache_time: now}
            {:ok, data}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, %{status: status}} ->
        Logger.warning("models.dev API returned #{status}, using fallback")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("Failed to fetch from models.dev API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Loads data asynchronously, trying live API first then falling back to file.

  Returns:
  - `{:ok, new_state}` - Data loaded successfully, state updated with source info
  - `{:error, reason}` - Both API and file fallback failed
  """
  @spec load_data_async(map()) :: {:ok, map()} | {:error, String.t()}
  def load_data_async(state) do
    cond do
      state.json_path != nil ->
        load_from_file(state, state.json_path)

      true ->
        # Try live API first
        case fetch_from_api(state) do
          {:ok, data} ->
            new_state = %{state | data_source: "live:models.dev"}
            {:ok, parse_and_update_state(new_state, data)}

          {:error, _} ->
            # Fall back to bundled
            bundled_path = get_bundled_json_path()

            if File.exists?(bundled_path) do
              load_from_file(state, bundled_path)
            else
              {:error, "No data source available: API failed and bundled file not found"}
            end
        end
    end
  end

  @doc """
  Loads data from a local JSON file.

  Returns:
  - `{:ok, new_state}` - File read and parsed successfully
  - `{:error, reason}` - File read error or JSON decode error
  """
  @spec load_from_file(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def load_from_file(state, path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            data_source =
              if path == get_bundled_json_path() do
                bundled_filename = Path.basename(path)
                "bundled:#{bundled_filename}"
              else
                "file:#{path}"
              end

            new_state = %{state | data_source: data_source}
            {:ok, parse_and_update_state(new_state, data)}

          {:error, reason} ->
            {:error, "Invalid JSON in #{path}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @bundled_json_filename "models_dev_api.json"

  defp get_bundled_json_path do
    # Look for bundled JSON in priv directory relative to this module
    priv_dir = :code.priv_dir(:code_puppy_control)
    Path.join(priv_dir, @bundled_json_filename)
  end

  # Delegate parsing back to Registry - we update the state with parsed data
  defp parse_and_update_state(state, data) do
    # Import Registry's parse_data function behavior
    CodePuppyControl.ModelsDevParser.Registry.parse_data(state, data)
  end
end
