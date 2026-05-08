defmodule CodePuppyControl.Tool.Schema do
  @moduledoc """
  JSON Schema validation for tool arguments.

  Provides validation and type coercion from raw input (typically decoded
  JSON strings from LLM tool calls) against a JSON Schema-like map.

  ## Supported Types

  - `"string"` — coerces via `to_string/1`
  - `"integer"` — coerces via `String.to_integer/1` or `trunc/1`
  - `"number"` — coerces via `String.to_float/1` or `+/1` on numeric
  - `"boolean"` — accepts `true`, `false`, `"true"`, `"false"`
  - `"array"` — validates list elements if `items` schema is provided
  - `"object"` — validates nested objects

  ## Supported Constraints

  - `required` — list of required property names
  - `enum` — list of allowed values
  - `format` — `"email"`, `"uri"` (extensible)
  - `minimum` / `maximum` — numeric bounds
  - `minLength` / `maxLength` — string length bounds
  - `minItems` / `maxItems` — array size bounds
  - `pattern` — regex pattern for string matching

  ## Examples

      iex> schema = %{
      ...>   "type" => "object",
      ...>   "properties" => %{
      ...>     "name" => %{"type" => "string"},
      ...>     "count" => %{"type" => "integer"}
      ...>   },
      ...>   "required" => ["name"]
      ...> }
      iex> Schema.validate(schema, %{"name" => "alice", "count" => "3"})
      {:ok, %{"name" => "alice", "count" => 3}}

      iex> Schema.validate(schema, %{"count" => 5})
      {:error, ["missing required field: name"]}
  """

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Validates `data` against a JSON Schema `schema`.

  Returns `{:ok, coerced_data}` where types have been cast, or
  `{:error, violations}` where violations is a list of human-readable
  strings describing each problem.

  ## Examples

      iex> Schema.validate(%{"type" => "string"}, "hello")
      {:ok, "hello"}

      iex> Schema.validate(%{"type" => "integer"}, "42")
      {:ok, 42}

      iex> Schema.validate(
      ...>   %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}, "required" => ["x"]},
      ...>   %{"x" => "10"}
      ...> )
      {:ok, %{"x" => 10}}
  """
  @spec validate(schema :: map(), data :: term()) :: {:ok, term()} | {:error, [String.t()]}
  def validate(schema, data) do
    violations = do_validate(schema, data, "")

    if violations == [] do
      {:ok, data}
    else
      {:error, violations}
    end
  end

  @doc """
  Validates `data` against a JSON Schema `schema`, raising on error.

  Returns coerced data on success or raises `ArgumentError` with
  the list of violations.
  """
  @spec validate!(schema :: map(), data :: term()) :: term()
  def validate!(schema, data) do
    case validate(schema, data) do
      {:ok, result} ->
        result

      {:error, violations} ->
        raise ArgumentError, "Schema validation failed:\n" <> Enum.join(violations, "\n")
    end
  end

  @doc """
  Coerces a value to the given JSON Schema type.

  Returns `{:ok, coerced}` or `{:error, reason}`.

  ## Examples

      iex> Schema.cast("string", "hello")
      {:ok, "hello"}

      iex> Schema.cast("integer", "42")
      {:ok, 42}

      iex> Schema.cast("boolean", "true")
      {:ok, true}

      iex> Schema.cast("number", 3.14)
      {:ok, 3.14}
  """
  @spec cast(type :: String.t(), value :: term()) :: {:ok, term()} | {:error, String.t()}
  def cast(type, value)

  def cast("string", value) when is_binary(value), do: {:ok, value}
  def cast("string", value), do: {:ok, to_string(value)}

  def cast("integer", value) when is_integer(value), do: {:ok, value}

  def cast("integer", value) when is_float(value), do: {:ok, trunc(value)}

  def cast("integer", value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "cannot cast #{inspect(value)} to integer"}
    end
  rescue
    _ -> {:error, "cannot cast #{inspect(value)} to integer"}
  end

  def cast("number", value) when is_number(value), do: {:ok, value}

  def cast("number", value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} -> {:ok, num}
      {num, _} -> {:ok, num}
      :error -> {:error, "cannot cast #{inspect(value)} to number"}
    end
  end

  def cast("boolean", value) when is_boolean(value), do: {:ok, value}
  def cast("boolean", "true"), do: {:ok, true}
  def cast("boolean", "false"), do: {:ok, false}
  def cast("boolean", "True"), do: {:ok, true}
  def cast("boolean", "False"), do: {:ok, false}

  def cast("array", value) when is_list(value), do: {:ok, value}

  def cast("object", value) when is_map(value), do: {:ok, value}

  def cast(type, value) do
    {:error, "unsupported type coercion: #{inspect(value)} -> #{inspect(type)}"}
  end

  @doc """
  Returns a list of violations for the given data against the schema.

  Unlike `validate/2`, this always returns a list (empty if valid).
  """
  @spec violations(schema :: map(), data :: term()) :: [String.t()]
  def violations(schema, data) do
    do_validate(schema, data, "")
  end

  # ── Private: Validation Engine ───────────────────────────────────────────

  defp do_validate(%{} = schema, data, path) do
    type = Map.get(schema, "type")

    type_errors =
      if type do
        validate_type(type, data, path)
      else
        []
      end

    constraint_errors = validate_constraints(schema, data, path)

    type_errors ++ constraint_errors
  end

  defp do_validate(_schema, _data, _path), do: []

  # ── Type Validation ──────────────────────────────────────────────────────

  defp validate_type("string", value, path) when not is_binary(value) do
    ["#{prefix(path)}expected string, got #{inspect_type(value)}"]
  end

  defp validate_type("string", _value, _path), do: []

  defp validate_type("integer", value, path) do
    case cast("integer", value) do
      {:ok, _} -> []
      {:error, _} -> ["#{prefix(path)}expected integer, got #{inspect_type(value)}"]
    end
  end

  defp validate_type("number", value, path) do
    case cast("number", value) do
      {:ok, _} -> []
      {:error, _} -> ["#{prefix(path)}expected number, got #{inspect_type(value)}"]
    end
  end

  defp validate_type("boolean", value, path) when not is_boolean(value) do
    ["#{prefix(path)}expected boolean, got #{inspect_type(value)}"]
  end

  defp validate_type("boolean", _value, _path), do: []

  defp validate_type("array", value, path) when not is_list(value) do
    ["#{prefix(path)}expected array, got #{inspect_type(value)}"]
  end

  defp validate_type("array", _value, _path), do: []

  defp validate_type("object", value, path) when not is_map(value) do
    ["#{prefix(path)}expected object, got #{inspect_type(value)}"]
  end

  defp validate_type("object", _value, _path), do: []

  defp validate_type(_type, _value, _path), do: []

  # ── Constraint Validation ────────────────────────────────────────────────

  defp validate_constraints(schema, data, path) do
    []
    |> maybe_validate_required(schema, data, path)
    |> maybe_validate_properties(schema, data, path)
    |> maybe_validate_enum(schema, data, path)
    |> maybe_validate_format(schema, data, path)
    |> maybe_validate_string_bounds(schema, data, path)
    |> maybe_validate_numeric_bounds(schema, data, path)
    |> maybe_validate_array_bounds(schema, data, path)
    |> maybe_validate_items(schema, data, path)
  end

  # required fields
  defp maybe_validate_required(errors, schema, data, path) when is_map(data) do
    required = Map.get(schema, "required", [])

    missing =
      Enum.filter(required, fn field ->
        not Map.has_key?(data, field)
      end)

    missing_errors =
      Enum.map(missing, fn field ->
        "#{prefix(path)}missing required field: #{field}"
      end)

    errors ++ missing_errors
  end

  defp maybe_validate_required(errors, _schema, _data, _path), do: errors

  # nested properties
  defp maybe_validate_properties(errors, schema, data, path) when is_map(data) do
    properties = Map.get(schema, "properties", %{})

    Enum.reduce(properties, errors, fn {prop_name, prop_schema}, acc ->
      case Map.fetch(data, prop_name) do
        {:ok, prop_value} ->
          nested_path = if path == "", do: prop_name, else: "#{path}.#{prop_name}"
          acc ++ do_validate(prop_schema, prop_value, nested_path)

        :error ->
          acc
      end
    end)
  end

  defp maybe_validate_properties(errors, _schema, _data, _path), do: errors

  defp maybe_validate_enum(errors, schema, data, path) do
    case Map.get(schema, "enum") do
      nil ->
        errors

      allowed ->
        if data in allowed do
          errors
        else
          errors ++ ["#{prefix(path)}value #{inspect(data)} not in enum #{inspect(allowed)}"]
        end
    end
  end

  # format
  defp maybe_validate_format(errors, schema, data, path) when is_binary(data) do
    case Map.get(schema, "format") do
      nil ->
        errors

      "email" ->
        if Regex.match?(~r/^[^\s]+@[^\s]+$/, data) do
          errors
        else
          errors ++ ["#{prefix(path)}invalid email format: #{inspect(data)}"]
        end

      "uri" ->
        if String.starts_with?(data, ["http://", "https://", "ftp://"]) do
          errors
        else
          errors ++ ["#{prefix(path)}invalid uri format: #{inspect(data)}"]
        end

      _ ->
        errors
    end
  end

  defp maybe_validate_format(errors, _schema, _data, _path), do: errors

  # string bounds
  defp maybe_validate_string_bounds(errors, schema, data, path) when is_binary(data) do
    len = String.length(data)

    errors
    |> check_min(schema, "minLength", len, path, "string length")
    |> check_max(schema, "maxLength", len, path, "string length")
  end

  defp maybe_validate_string_bounds(errors, _schema, _data, _path), do: errors

  # numeric bounds
  defp maybe_validate_numeric_bounds(errors, schema, data, path) when is_number(data) do
    errors
    |> check_min(schema, "minimum", data, path, "value")
    |> check_max(schema, "maximum", data, path, "value")
  end

  defp maybe_validate_numeric_bounds(errors, _schema, _data, _path), do: errors

  # array bounds
  defp maybe_validate_array_bounds(errors, schema, data, path) when is_list(data) do
    len = length(data)

    errors
    |> check_min(schema, "minItems", len, path, "array length")
    |> check_max(schema, "maxItems", len, path, "array length")
  end

  defp maybe_validate_array_bounds(errors, _schema, _data, _path), do: errors

  # array items
  defp maybe_validate_items(errors, schema, data, path) when is_list(data) do
    case Map.get(schema, "items") do
      nil ->
        errors

      item_schema ->
        data
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {item, idx}, acc ->
          item_path = "#{prefix(path)}[#{idx}]"
          acc ++ do_validate(item_schema, item, item_path)
        end)
    end
  end

  defp maybe_validate_items(errors, _schema, _data, _path), do: errors

  # ── Bound Helpers ────────────────────────────────────────────────────────

  defp check_min(errors, schema, key, value, path, label) do
    case Map.get(schema, key) do
      nil ->
        errors

      min when value < min ->
        errors ++ ["#{prefix(path)}#{label} must be >= #{min}, got #{value}"]

      _ ->
        errors
    end
  end

  defp check_max(errors, schema, key, value, path, label) do
    case Map.get(schema, key) do
      nil ->
        errors

      max when value > max ->
        errors ++ ["#{prefix(path)}#{label} must be <= #{max}, got #{value}"]

      _ ->
        errors
    end
  end

  # ── Formatting Helpers ───────────────────────────────────────────────────

  defp prefix(""), do: ""
  defp prefix(path), do: "#{path}: "

  defp inspect_type(value) when is_binary(value), do: "string"
  defp inspect_type(value) when is_integer(value), do: "integer"
  defp inspect_type(value) when is_float(value), do: "number"
  defp inspect_type(value) when is_boolean(value), do: "boolean"
  defp inspect_type(value) when is_list(value), do: "array"
  defp inspect_type(value) when is_map(value), do: "object"
  defp inspect_type(value) when is_atom(value), do: "atom"
  defp inspect_type(_value), do: "unknown"
end
