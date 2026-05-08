defmodule CodePuppyControl.Messaging.WireEvent do
  @moduledoc """
  Wire-format wrapper helpers for Agent→UI structured messaging.

  Converts between internal message maps and the JSON-safe wire envelope
  defined in `event_schema.md`:

      %{
        "event_type"  => category,     # e.g. "system", "agent", "tool_output"
        "run_id"      => run_id,      # execution run identifier
        "session_id"  => session_id,  # session grouping
        "timestamp"   => unix_ms,     # Unix timestamp in milliseconds
        "payload"     => %{...}       # message-specific fields (excludes wrapper fields)
      }

  ## Payload Exclusion Rule

  The `payload` map contains message-specific data **only**. These wrapper-level
  fields are lifted out and **never** appear inside `payload`:

  - `event_type` (maps to category)
  - `run_id`
  - `session_id`
  - `timestamp` / `timestamp_unix_ms`

  The `id` field and all message-specific fields (e.g. `level`, `text`,
  `is_markdown`, `category`) remain inside `payload`.

  ## Design Decision: timestamp_unix_ms

  `timestamp_unix_ms` is an **internal convenience** that always equals the
  wrapper's `timestamp`. It is stored internally for parity with the Python
  `BaseMessage` but is **not** duplicated into `payload` — the canonical
  location is the wrapper's `timestamp` field.
  """

  alias CodePuppyControl.Messaging.Types

  # Fields promoted from internal map to wrapper envelope.
  # These are EXCLUDED from payload during to_wire.
  @wrapper_keys ~w(event_type run_id session_id timestamp timestamp_unix_ms)

  @doc """
  Converts an internal message map to a JSON-safe wire envelope.

  ## Internal Map Shape

      %{
        "id"               => "uuid",
        "category"         => "system",
        "level"            => "info",       # TextMessage-specific
        "text"             => "Hello",      # TextMessage-specific
        "is_markdown"      => false,        # TextMessage-specific
        "run_id"           => "run-abc",
        "session_id"       => "session-xyz",
        "timestamp_unix_ms" => 1713123456789
      }

  ## Wire Output Shape

      %{
        "event_type"  => "system",
        "run_id"      => "run-abc",
        "session_id"  => "session-xyz",
        "timestamp"   => 1713123456789,
        "payload"     => %{
          "id"         => "uuid",
          "category"   => "system",
          "level"      => "info",
          "text"       => "Hello",
          "is_markdown" => false
        }
      }

  Returns `{:ok, wire_map}` or `{:error, reason}`.
  """
  @spec to_wire(map()) :: {:ok, map()} | {:error, term()}
  def to_wire(internal) when is_map(internal) do
    with :ok <- validate_payload_string_keys(internal),
         {:ok, category} <- validate_category(internal),
         {:ok, _level} <- validate_level_if_present(internal),
         {:ok, timestamp} <- resolve_timestamp(internal) do
      run_id = internal["run_id"]
      session_id = internal["session_id"]

      payload =
        internal
        |> Map.drop(@wrapper_keys)
        # Also drop run_id/session_id from payload if they snuck in as atom keys
        |> Map.drop([:run_id, :session_id, :timestamp, :timestamp_unix_ms, :event_type])

      wire = %{
        "event_type" => category,
        "run_id" => run_id,
        "session_id" => session_id,
        "timestamp" => timestamp,
        "payload" => payload
      }

      {:ok, wire}
    end
  end

  def to_wire(other), do: {:error, {:not_a_map, other}}

  @doc """
  Converts a wire envelope back to an internal message map.

  Validates the envelope shape, checks `event_type` is a known category,
  and normalizes the result.

  ## Required Wrapper Fields

  - `"event_type"` — must be a valid MessageCategory
  - `"timestamp"` — must be an integer (unix ms)
  - `"payload"` — must be a map

  ## Returns

  - `{:ok, internal_map}` — normalized internal representation
  - `{:error, reason}` — for malformed input (never raises)

  ## Examples

      iex> wire = %{
      ...>   "event_type" => "system",
      ...>   "run_id" => "r1",
      ...>   "session_id" => "s1",
      ...>   "timestamp" => 1713123456789,
      ...>   "payload" => %{"id" => "msg-1", "category" => "system", "level" => "info", "text" => "Hi", "is_markdown" => false}
      ...> }
      iex> {:ok, internal} = CodePuppyControl.Messaging.WireEvent.from_wire(wire)
      iex> internal["category"]
      "system"
      iex> internal["timestamp_unix_ms"]
      1713123456789
  """
  @spec from_wire(map()) :: {:ok, map()} | {:error, term()}
  def from_wire(wire) when is_map(wire) do
    with :ok <- require_field(wire, "event_type"),
         :ok <- require_field(wire, "timestamp"),
         :ok <- require_field(wire, "payload"),
         {:ok, category} <- validate_wire_event_type(wire),
         :ok <- validate_timestamp(wire),
         :ok <- validate_payload(wire) do
      payload = wire["payload"]
      timestamp = wire["timestamp"]

      internal =
        payload
        |> Map.merge(%{
          "category" => category,
          "run_id" => wire["run_id"],
          "session_id" => wire["session_id"],
          "timestamp_unix_ms" => timestamp
        })

      {:ok, internal}
    end
  end

  def from_wire(other), do: {:error, {:not_a_map, other}}

  # ── Private helpers ────────────────────────────────────────────────────────

  defp validate_category(internal) do
    category = internal["category"]

    cond do
      category == nil -> {:error, :missing_category}
      true -> Types.validate_category(category)
    end
  end

  defp validate_level_if_present(internal) do
    cond do
      not Map.has_key?(internal, "level") -> {:ok, nil}
      internal["level"] == nil -> {:error, {:invalid_level, nil}}
      true -> Types.validate_level(internal["level"])
    end
  end

  defp resolve_timestamp(internal) do
    case Map.get(internal, "timestamp_unix_ms") do
      nil -> {:ok, System.system_time(:millisecond)}
      ts when is_integer(ts) -> {:ok, ts}
      other -> {:error, {:invalid_timestamp_unix_ms, other}}
    end
  end

  defp validate_payload_string_keys(internal) do
    payload_preview = Map.drop(internal, @wrapper_keys)

    case Enum.find(payload_preview, fn {k, _v} -> not is_binary(k) end) do
      nil -> :ok
      {k, _v} -> {:error, {:non_string_key, k}}
    end
  end

  defp require_field(map, field) do
    if Map.has_key?(map, field) do
      :ok
    else
      {:error, {:missing_field, field}}
    end
  end

  defp validate_wire_event_type(wire) do
    event_type = wire["event_type"]
    Types.validate_category(event_type)
  end

  defp validate_timestamp(wire) do
    case wire["timestamp"] do
      ts when is_integer(ts) -> :ok
      other -> {:error, {:invalid_timestamp, other}}
    end
  end

  defp validate_payload(wire) do
    case wire["payload"] do
      p when is_map(p) ->
        with :ok <- validate_payload_string_keys_incoming(p),
             :ok <- validate_payload_no_wrapper_fields(p),
             :ok <- validate_payload_level(p) do
          :ok
        end

      other ->
        {:error, {:invalid_payload, other}}
    end
  end

  defp validate_payload_string_keys_incoming(payload) do
    case Enum.find(payload, fn {k, _v} -> not is_binary(k) end) do
      nil -> :ok
      {k, _v} -> {:error, {:non_string_key, k}}
    end
  end

  @wrapper_only_fields ~w(run_id session_id timestamp timestamp_unix_ms event_type)

  defp validate_payload_no_wrapper_fields(payload) do
    case Enum.find(@wrapper_only_fields, &Map.has_key?(payload, &1)) do
      nil -> :ok
      field -> {:error, {:wrapper_field_in_payload, field}}
    end
  end

  defp validate_payload_level(payload) do
    cond do
      not Map.has_key?(payload, "level") ->
        :ok

      payload["level"] == nil ->
        {:error, {:invalid_level, nil}}

      true ->
        case Types.validate_level(payload["level"]) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end
end
