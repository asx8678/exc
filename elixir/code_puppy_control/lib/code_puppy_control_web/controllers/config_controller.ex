defmodule CodePuppyControlWeb.ConfigController do
  @moduledoc """
  REST API controller for runtime configuration management.

  Replaces `code_puppy/api/routers/config.py` from the Python FastAPI server.

  ## Endpoints

  - `GET /api/config` — List all configuration keys and values
  - `GET /api/config/keys` — List all valid configuration keys
  - `GET /api/config/:key` — Get a specific configuration value
  - `PUT /api/config/:key` — Set a configuration value
  - `DELETE /api/config/:key` — Reset a configuration value to default
  """

  use CodePuppyControlWeb, :controller

  require Logger

  alias CodePuppyControl.Config
  alias CodePuppyControl.Config.Writer

  # Pattern matching sensitive keys for redaction (matches Python's _SENSITIVE_PATTERNS)
  @sensitive_patterns ~r/(api_key|token|secret|password|credential|auth_key|private_key)/i
  @redacted "********"

  @doc """
  GET /api/config

  Lists all configuration keys and their current values.
  Sensitive values are redacted.
  """
  def index(conn, _params) do
    config =
      Config.get_config_keys()
      |> Enum.map(fn key ->
        {key, redact(key, Config.get_value(key))}
      end)
      |> Map.new()

    json(conn, %{config: config})
  end

  @doc """
  GET /api/config/keys

  Returns a list of all valid configuration keys.
  """
  def keys(conn, _params) do
    json(conn, Config.get_config_keys())
  end

  @doc """
  GET /api/config/:key

  Gets a specific configuration value.
  Sensitive values are redacted.
  """
  def show(conn, %{"key" => key}) do
    valid_keys = Config.get_config_keys()

    if key in valid_keys do
      value = Config.get_value(key)
      json(conn, %{key: key, value: redact(key, value)})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Config key '#{key}' not found. Valid keys: #{inspect(valid_keys)}"})
    end
  end

  @doc """
  PUT /api/config/:key

  Sets a configuration value.

  Auth: Protected (Wave 5 will add auth plug; currently open for loopback-only deployment).

  Request body:
      { "value": "new_value" }
  """
  def update(conn, %{"key" => key, "value" => value}) do
    valid_keys = Config.get_config_keys()

    cond do
      key not in valid_keys ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Config key '#{key}' not found. Valid keys: #{inspect(valid_keys)}"})

      not scalar_value?(value) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Config values must be a string, number, boolean, or null",
          received_type: value_type_name(value)
        })

      true ->
        case safe_set_value(key, to_string(value)) do
          :ok ->
            # Read back the persisted value for response (may differ from input)
            updated_value = Config.get_value(key)
            json(conn, %{key: key, value: redact(key, updated_value)})

          {:error, reason} ->
            Logger.error("Failed to set config key '#{key}': #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to set config value", details: inspect(reason)})
        end
    end
  end

  def update(conn, %{"key" => _key}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required field: value"})
  end

  @doc """
  DELETE /api/config/:key

  Resets a configuration value to default (removes from config file).

  Auth: Protected (Wave 5 will add auth plug; currently open for loopback-only deployment).
  """
  def delete(conn, %{"key" => key}) do
    valid_keys = Config.get_config_keys()

    if key in valid_keys do
      case safe_delete_value(key) do
        :ok ->
          json(conn, %{message: "Config key '#{key}' reset to default"})

        {:error, reason} ->
          Logger.error("Failed to reset config key '#{key}': #{inspect(reason)}")

          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to reset config value", details: inspect(reason)})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Config key '#{key}' not found. Valid keys: #{inspect(valid_keys)}"})
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  # Safely call Writer.set_value, returning {:error, reason} if the GenServer
  # is not running or the write fails.
  defp safe_set_value(key, value) do
    try do
      Config.set_value(key, value)
      :ok
    catch
      :exit, reason -> {:error, reason}
      :error, reason -> {:error, reason}
    end
  end

  defp safe_delete_value(key) do
    try do
      Writer.delete_value(key)
      :ok
    catch
      :exit, reason -> {:error, reason}
      :error, reason -> {:error, reason}
    end
  end

  defp redact(key, value) when is_binary(key) do
    if Regex.match?(@sensitive_patterns, key) do
      @redacted
    else
      value
    end
  end

  defp redact(_key, value), do: value

  # Config values must be scalar types that can be safely serialized
  # to a string via `to_string/1`. Maps and lists crash or produce
  # garbage output.
  defp scalar_value?(value) when is_binary(value), do: true
  defp scalar_value?(value) when is_number(value), do: true
  defp scalar_value?(value) when is_boolean(value), do: true
  defp scalar_value?(nil), do: true
  defp scalar_value?(_), do: false

  defp value_type_name(value) when is_map(value), do: "map"
  defp value_type_name(value) when is_list(value), do: "list"
  defp value_type_name(value) when is_tuple(value), do: "tuple"
  defp value_type_name(_), do: "unknown"
end
