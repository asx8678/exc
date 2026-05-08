defmodule CodePuppyControl.Evals.Logger do
  @moduledoc """
  Persists `CodePuppyControl.Evals.Result` values to JSON logs.

  Writes to `<cwd>/evals/logs/<sanitized>.json` by default — the SAME directory
  Python writes to — so `diff evals/logs/<name>.json` across runs is the
  parity gate for .

  JSON key order is preserved (name, timestamp, model, duration_seconds,
  response_text, tool_calls) to match the Python reference output using
  `Jason.OrderedObject`.

  Log directory can be overridden with:

      config :code_puppy_control, :evals_log_dir, "/tmp/my_evals"

  ## Timestamp format

  Python's `datetime.now().isoformat()` produces a **naive local** timestamp
  (no timezone offset). We use `NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()`
  to produce a naive UTC timestamp, which is the closest reproducible equivalent.
  Both omit the timezone suffix, making the JSON output structurally identical.
  """

  alias CodePuppyControl.Evals.{Result, ToolCall}

  @response_truncate 2000

  @doc """
  Persist an eval result to `evals/logs/<sanitized name>.json`.

  ## Example

      iex> result = %CodePuppyControl.Evals.Result{response_text: "hi", model_name: "mock"}
      iex> CodePuppyControl.Evals.Logger.log_eval("Smoke Test", result)
      :ok
  """
  @spec log_eval(String.t(), Result.t()) :: :ok
  def log_eval(name, %Result{} = result) when is_binary(name) do
    dir = resolve_log_dir()
    File.mkdir_p!(dir)

    path = Path.join(dir, sanitize_name(name) <> ".json")
    json = encode(name, result)
    File.write!(path, json)
    :ok
  end

  @doc """
  Normalize a name to a file-safe lowercase form.

  Mirrors Python: `name.replace(" ", "_").replace("/", "_").lower()`

  ## Examples

      iex> CodePuppyControl.Evals.Logger.sanitize_name("Smoke Test")
      "smoke_test"

      iex> CodePuppyControl.Evals.Logger.sanitize_name("evals/unit/sub_test")
      "evals_unit_sub_test"
  """
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) do
    name
    |> String.replace(" ", "_")
    |> String.replace("/", "_")
    |> String.downcase()
  end

  @doc """
  Directory where eval logs are written.

  Defaults to `<cwd>/evals/logs`. Override via application config:

      config :code_puppy_control, :evals_log_dir, "/tmp/my_evals"
  """
  @spec resolve_log_dir() :: String.t()
  def resolve_log_dir do
    Application.get_env(:code_puppy_control, :evals_log_dir) ||
      Path.join([File.cwd!(), "evals", "logs"])
  end

  # --- private ---

  defp encode(name, %Result{} = r) do
    ordered = [
      {"name", name},
      {"timestamp", iso_now()},
      {"model", r.model_name},
      {"duration_seconds", r.duration_seconds},
      {"response_text", truncate(r.response_text, @response_truncate)},
      {"tool_calls", Enum.map(r.tool_calls, &ToolCall.to_map/1)}
    ]

    # Use OrderedObject for strict key-order parity with Python json.dumps
    if Code.ensure_loaded?(Jason.OrderedObject) do
      ordered
      |> Jason.OrderedObject.new()
      |> Jason.encode!(pretty: true)
    else
      ordered |> Map.new() |> Jason.encode!(pretty: true)
    end
  end

  defp iso_now do
    # Python datetime.now().isoformat() is naive local; we use naive UTC for
    # reproducibility while matching the "no timezone suffix" format.
    NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()
  end

  defp truncate(nil, _n), do: ""
  defp truncate(s, n) when is_binary(s), do: String.slice(s, 0, n)
end
