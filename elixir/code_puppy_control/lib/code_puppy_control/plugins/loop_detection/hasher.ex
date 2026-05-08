defmodule CodePuppyControl.Plugins.LoopDetection.Hasher do
  @moduledoc """
  Pure functions for hashing and normalizing tool calls.

  Creates stable, order-independent hashes for tool calls to detect
  repetitive patterns. Uses MD5 truncated to 12 characters (sufficient
  for loop detection, not for security).
  """

  @doc """
  Create a hash of a tool call for loop detection tracking.

  Normalizes args, generates a stable key, then hashes it.
  """
  @spec hash_tool_call(String.t(), map()) :: String.t()
  def hash_tool_call(tool_name, tool_args) do
    args = normalize_tool_args(tool_args)
    key = stable_tool_key(tool_name, args)
    blob = "#{tool_name}:#{key}"

    :crypto.hash(:md5, blob)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  @doc """
  Normalize tool arguments to a stable map representation.
  """
  @spec normalize_tool_args(term()) :: map()
  def normalize_tool_args(tool_args) when is_map(tool_args), do: tool_args

  def normalize_tool_args(tool_args) when is_binary(tool_args) do
    case Jason.decode(tool_args) do
      {:ok, parsed} when is_map(parsed) -> parsed
      {:ok, parsed} -> %{"_parsed" => parsed}
      {:error, _} -> %{"_raw" => tool_args}
    end
  end

  def normalize_tool_args(nil), do: %{}
  def normalize_tool_args(other), do: %{"_value" => other}

  @doc """
  Generate a stable key for a tool call based on its name and salient args.
  """
  @spec stable_tool_key(String.t(), map()) :: String.t()
  def stable_tool_key(tool_name, args) do
    cond do
      tool_name == "read_file" ->
        stable_read_file_key(args)

      tool_name in ~w(write_file replace_in_file create_file) ->
        args |> Jason.encode!() |> stable_sort_json()

      true ->
        stable_generic_key(args)
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp stable_read_file_key(args) do
    path = args["path"] || args["file_path"] || ""
    start_line = args["start_line"]
    num_lines = args["num_lines"]
    bucket_size = 200

    start =
      case parse_int(start_line) do
        nil -> 1
        n -> n
      end

    bucket_start = max(div(start - 1, bucket_size), 0)

    case parse_int(num_lines) do
      nil ->
        "#{path}:#{bucket_start}"

      n ->
        end_line = start + n
        bucket_end = max(div(end_line - 1, bucket_size), 0)
        "#{path}:#{bucket_start}-#{bucket_end}"
    end
  end

  defp stable_generic_key(args) do
    salient_fields = ~w(path file_path directory search_string command url pattern)

    stable_args =
      salient_fields
      |> Enum.filter(fn k -> Map.get(args, k) != nil end)
      |> Enum.into(%{}, fn k -> {k, args[k]} end)

    if map_size(stable_args) > 0 do
      stable_args |> Jason.encode!() |> stable_sort_json()
    else
      args |> Jason.encode!() |> stable_sort_json()
    end
  end

  defp stable_sort_json(json_string), do: json_string

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
