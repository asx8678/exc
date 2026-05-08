defmodule CodePuppyControl.Tools.StagedChanges.StagedChange do
  @moduledoc """
  A single staged change entry.

  Validates that `applied` and `rejected` are not both `true`,
  matching the Python `__post_init__` guard.

  ## Serialization

  `from_map/1` safely handles:
  - Python-persisted uppercase change_type values (`"CREATE"`, `"REPLACE"`, etc.)
  - Unknown or missing change_type values
  - Missing optional fields (defaults applied)
  - Malformed applied/rejected values (coerced to boolean)
  - Both applied+rejected=true (treated as rejected to be safe)

  Returns `{:ok, change}` or `{:error, reason}` — never raises on bad input.
  """

  @derive Jason.Encoder
  @enforce_keys [:change_id, :change_type, :file_path]
  defstruct [
    :change_id,
    :change_type,
    :file_path,
    :content,
    :old_str,
    :new_str,
    :snippet,
    :description,
    created_at: nil,
    applied: false,
    rejected: false
  ]

  @type t :: %__MODULE__{}

  # Safe allowlist mapping for change_type strings to atoms.
  # Supports both Python-persisted uppercase (CREATE, REPLACE, etc.)
  # and Elixir-internal lowercase (create, replace, etc.).
  # No unsafe atom creation — only these atoms can ever be produced.
  @change_type_map %{
    "create" => :create,
    "CREATE" => :create,
    "replace" => :replace,
    "REPLACE" => :replace,
    "delete_snippet" => :delete_snippet,
    "DELETE_SNIPPET" => :delete_snippet,
    "delete_file" => :delete_file,
    "DELETE_FILE" => :delete_file
  }

  @doc """
  Create a new StagedChange with validation.

  Raises `ArgumentError` if both `applied` and `rejected` are true,
  matching the Python ValueError guard.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
    |> validate!()
  end

  defp validate!(%__MODULE__{applied: true, rejected: true}) do
    raise ArgumentError, "StagedChange cannot be both applied and rejected"
  end

  defp validate!(change), do: change

  @doc """
  Serialize change to map (matches Python `to_dict`).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = c) do
    %{
      "change_id" => c.change_id,
      "change_type" => Atom.to_string(c.change_type),
      "file_path" => c.file_path,
      "content" => c.content,
      "old_str" => c.old_str,
      "new_str" => c.new_str,
      "snippet" => c.snippet,
      "created_at" => c.created_at,
      "description" => c.description,
      "applied" => c.applied,
      "rejected" => c.rejected
    }
  end

  @doc """
  Deserialize change from map (matches Python `from_dict`).

  Robust against malformed input:
  - Handles Python-persisted uppercase change_type (`"CREATE"`, `"REPLACE"`, etc.)
  - Handles unknown change_type → `{:error, reason}`
  - Handles missing required fields → `{:error, reason}`
  - Handles malformed applied/rejected → coerced to boolean
  - Handles applied+rejected=true → treated as rejected (safe default)
  - Never raises on bad input, never crashes the caller

  Returns `{:ok, change}` or `{:error, reason}`.
  """
  @spec from_map(map() | term()) :: {:ok, t()} | {:error, String.t()}
  def from_map(data) when is_map(data) do
    with {:ok, change_id} <- require_field(data, "change_id"),
         {:ok, change_type} <- parse_change_type(data["change_type"]),
         {:ok, file_path} <- require_field(data, "file_path") do
      applied = to_bool(data["applied"])
      rejected = to_bool(data["rejected"])

      # If both are true, treat as rejected (safe: never auto-apply a
      # change that was explicitly rejected)
      {applied, rejected} =
        if applied and rejected do
          {false, true}
        else
          {applied, rejected}
        end

      {:ok,
       %__MODULE__{
         change_id: change_id,
         change_type: change_type,
         file_path: file_path,
         content: data["content"],
         old_str: data["old_str"],
         new_str: data["new_str"],
         snippet: data["snippet"],
         created_at: data["created_at"],
         description: data["description"] || "",
         applied: applied,
         rejected: rejected
       }}
    end
  end

  # Catch-all for non-map input: strings, numbers, nil, lists, etc.
  # Returns {:error, reason} instead of raising FunctionClauseError.
  def from_map(other) when not is_map(other) do
    {:error, "expected map for from_map, got: #{inspect(other)}"}
  end

  @doc """
  Returns the safe change_type allowlist map.
  Useful for tests and validation.
  """
  @spec change_type_map() :: %{String.t() => atom()}
  def change_type_map, do: @change_type_map

  # ── Private helpers ──────────────────────────────────────────────────────

  defp require_field(data, key) do
    case Map.get(data, key) do
      nil -> {:error, "missing required field: #{key}"}
      "" -> {:error, "empty required field: #{key}"}
      value -> {:ok, value}
    end
  end

  defp parse_change_type(nil), do: {:error, "missing required field: change_type"}

  defp parse_change_type(type) when is_atom(type) do
    if type in [:create, :replace, :delete_snippet, :delete_file] do
      {:ok, type}
    else
      {:error, "unknown change_type atom: #{inspect(type)}"}
    end
  end

  defp parse_change_type(type) when is_binary(type) do
    case Map.get(@change_type_map, type) do
      nil -> {:error, "unknown change_type string: #{inspect(type)}"}
      atom -> {:ok, atom}
    end
  end

  defp parse_change_type(other), do: {:error, "invalid change_type: #{inspect(other)}"}

  # Coerce various truthy/falsy values to boolean.
  # Handles: true/false, "true"/"false", 1/0, nil → false
  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(nil), do: false
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool(_), do: false
end
