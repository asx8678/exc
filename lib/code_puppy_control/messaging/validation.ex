defmodule CodePuppyControl.Messaging.Validation do
  @moduledoc """
  Shared validation helpers for Agent→UI message constructors.

  Provides reusable primitives for type checking, numeric bounds,
  literal membership, optional-nil fields, and extra-key rejection.
  All helpers return `{:ok, value}` or `{:error, reason}` — never raise.
  """

  alias CodePuppyControl.Messaging.Types

  # ── ID & Timestamp ─────────────────────────────────────────────────────────

  @doc "Generates a 32-char lowercase hex message ID without Ecto dependency."
  @spec generate_id() :: String.t()
  def generate_id do
    ts = System.system_time(:nanosecond)
    uniq = :erlang.unique_integer([:positive])

    :crypto.hash(:sha256, "#{ts}-#{uniq}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  @doc "Resolves `timestamp_unix_ms` from fields, defaulting to now if absent."
  @spec resolve_timestamp(map()) :: {:ok, integer()} | {:error, term()}
  def resolve_timestamp(fields) do
    case Map.get(fields, "timestamp_unix_ms") do
      nil -> {:ok, System.system_time(:millisecond)}
      ts when is_integer(ts) -> {:ok, ts}
      other -> {:error, {:invalid_timestamp_unix_ms, other}}
    end
  end

  # ── String fields ──────────────────────────────────────────────────────────

  @doc "Validates a required string field is present and binary."
  @spec require_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def require_string(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, key, other}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  @doc "Validates an optional string-or-nil field."
  @spec optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def optional_string(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, v} when is_binary(v) or is_nil(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, key, other}}
      :error -> {:ok, nil}
    end
  end

  # ── Numeric fields ──────────────────────────────────────────────────────────

  @doc "Validates a required integer field with optional lower bound."
  @spec require_integer(map(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def require_integer(fields, key, opts \\ []) do
    min = Keyword.get(opts, :min)

    case Map.fetch(fields, key) do
      {:ok, v} when is_integer(v) ->
        if min != nil and v < min do
          {:error, {:value_below_min, key, v, min}}
        else
          {:ok, v}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:error, {:missing_required_field, key}}
    end
  end

  @doc "Validates an optional integer-or-nil field with optional lower bound."
  @spec optional_integer(map(), String.t(), keyword()) ::
          {:ok, integer() | nil} | {:error, term()}
  def optional_integer(fields, key, opts \\ []) do
    min = Keyword.get(opts, :min)

    case Map.fetch(fields, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, v} when is_integer(v) ->
        if min != nil and v < min do
          {:error, {:value_below_min, key, v, min}}
        else
          {:ok, v}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:ok, nil}
    end
  end

  @doc "Validates a required numeric field (int or float) with optional lower bound."
  @spec require_number(map(), String.t(), keyword()) ::
          {:ok, number()} | {:error, term()}
  def require_number(fields, key, opts \\ []) do
    min = Keyword.get(opts, :min)

    case Map.fetch(fields, key) do
      {:ok, v} when is_number(v) ->
        if min != nil and v < min do
          {:error, {:value_below_min, key, v, min}}
        else
          {:ok, v}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:error, {:missing_required_field, key}}
    end
  end

  @doc "Validates an optional numeric-or-nil field with optional lower bound."
  @spec optional_number(map(), String.t(), keyword()) ::
          {:ok, number() | nil} | {:error, term()}
  def optional_number(fields, key, opts \\ []) do
    min = Keyword.get(opts, :min)

    case Map.fetch(fields, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, v} when is_number(v) ->
        if min != nil and v < min do
          {:error, {:value_below_min, key, v, min}}
        else
          {:ok, v}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:ok, nil}
    end
  end

  # ── Boolean fields ─────────────────────────────────────────────────────────

  @doc "Validates a required boolean field."
  @spec require_boolean(map(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def require_boolean(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, key, other}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  @doc "Validates an optional boolean field with a default."
  @spec optional_boolean(map(), String.t(), boolean()) ::
          {:ok, boolean()} | {:error, term()}
  def optional_boolean(fields, key, default \\ false) do
    case Map.fetch(fields, key) do
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:ok, other} -> {:error, {:invalid_field_type, key, other}}
      :error -> {:ok, default}
    end
  end

  # ── Literal fields ─────────────────────────────────────────────────────────

  @doc "Validates a required field against a set of allowed literal strings."
  @spec require_literal(map(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def require_literal(fields, key, allowed) do
    case Map.fetch(fields, key) do
      {:ok, v} when is_binary(v) ->
        if v in allowed do
          {:ok, v}
        else
          {:error, {:invalid_literal, key, v, allowed}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:error, {:missing_required_field, key}}
    end
  end

  @doc "Validates an optional literal-or-nil field against allowed values."
  @spec optional_literal(map(), String.t(), [String.t()]) ::
          {:ok, String.t() | nil} | {:error, term()}
  def optional_literal(fields, key, allowed) do
    case Map.fetch(fields, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, v} when is_binary(v) ->
        if v in allowed do
          {:ok, v}
        else
          {:error, {:invalid_literal, key, v, allowed}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}

      :error ->
        {:ok, nil}
    end
  end

  # ── Category validation ────────────────────────────────────────────────────

  @doc """
  Validates category against an expected default.

  If `"category"` is absent in fields, uses `default`.
  If present, must match `default` exactly (mismatch rejected).
  Returns `{:ok, category}` or `{:error, reason}`.
  """
  @spec validate_category_default(map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def validate_category_default(fields, default) do
    case Map.fetch(fields, "category") do
      :error ->
        Types.validate_category(default)

      {:ok, cat} ->
        with {:ok, _} <- Types.validate_category(cat) do
          if cat == default do
            {:ok, cat}
          else
            {:error, {:category_mismatch, expected: default, got: cat}}
          end
        end
    end
  end

  # ── List-of-struct validation ──────────────────────────────────────────────

  @doc """
  Validates a list field where each element is validated by `element_validator`.

  `element_validator` is a function `(map() -> {:ok, map()} | {:error, term()})`.
  Rejects non-list, non-map elements, and validates each element individually.
  """
  @spec validate_list(map(), String.t(), (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def validate_list(fields, key, element_validator) do
    case Map.fetch(fields, key) do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        validate_list_elements(key, list, element_validator, [])

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}
    end
  end

  defp validate_list_elements(_key, [], _validator, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_list_elements(key, [head | tail], validator, acc) do
    if is_map(head) do
      case validator.(head) do
        {:ok, validated} ->
          validate_list_elements(key, tail, validator, [validated | acc])

        {:error, reason} ->
          {:error, {:invalid_list_element, key, reason}}
      end
    else
      {:error, {:invalid_list_element, key, {:not_a_map, head}}}
    end
  end

  # ── Map-of-string-to-string validation ─────────────────────────────────────

  @doc "Validates a map field where all keys and values must be strings."
  @spec optional_string_map(map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def optional_string_map(fields, key) do
    case Map.fetch(fields, key) do
      :error ->
        {:ok, %{}}

      {:ok, m} when is_map(m) ->
        if Enum.all?(m, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, m}
        else
          {:error, {:invalid_field_type, key, :not_string_to_string_map}}
        end

      {:ok, other} ->
        {:error, {:invalid_field_type, key, other}}
    end
  end

  # ── Extra fields rejection ─────────────────────────────────────────────────

  @doc """
  Rejects keys in `fields` that are not in `allowed_keys`.

  Used to enforce extra='forbid' semantics at constructor boundaries.
  """
  @spec reject_extra_keys(map(), MapSet.t()) :: :ok | {:error, term()}
  def reject_extra_keys(fields, allowed_keys) do
    extra =
      fields
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))

    case extra do
      [] -> :ok
      _ -> {:error, {:extra_fields_not_allowed, extra}}
    end
  end

  # ── Base message assembly ──────────────────────────────────────────────────

  @doc """
  Assembles the base message fields (id, category, run_id, session_id, timestamp_unix_ms)
  with validated category and auto-generated defaults.
  """
  @spec assemble_base(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def assemble_base(fields, category) do
    with {:ok, _} <- Types.validate_category(category),
         {:ok, ts} <- resolve_timestamp(fields) do
      {:ok,
       %{
         "id" => Map.get(fields, "id") || generate_id(),
         "category" => category,
         "run_id" => Map.get(fields, "run_id"),
         "session_id" => Map.get(fields, "session_id"),
         "timestamp_unix_ms" => ts
       }}
    end
  end
end
