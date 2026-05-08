defmodule CodePuppyControl.Agent.ResponseValidator do
  @moduledoc """
  Optional structured-output validation for LLM agent responses.
  """

  alias Ecto.Changeset

  @type response :: %{text: String.t(), tool_calls: [map()]}
  @type errors :: %{atom() => [String.t()] | errors()}
  @type validate_result :: {:ok, struct()} | {:error, errors()}

  @callback changeset(struct :: struct(), params :: map()) :: Ecto.Changeset.t()

  @spec validate(response(), module() | nil) :: validate_result() | {:ok, response()}
  def validate(response, nil), do: {:ok, response}

  def validate(response, schema_module) when is_atom(schema_module) do
    with {:ok, params} <- extract_json(response.text) do
      struct = schema_module.__struct__()
      changeset = schema_module.changeset(struct, params)

      if changeset.valid? do
        {:ok, Changeset.apply_changes(changeset)}
      else
        {:error, collect_errors(changeset)}
      end
    end
  end

  @spec extract_json(String.t()) :: {:ok, map()} | {:error, errors()}
  def extract_json(text) when is_binary(text) do
    text = String.trim(text)

    case Jason.decode(text) do
      {:ok, params} when is_map(params) -> {:ok, params}
      {:ok, _not_a_map} -> try_fallback_extraction(text)
      {:error, _} -> try_fallback_extraction(text)
    end
  end

  def extract_json(_), do: {:error, %{json: ["response text is not a string"]}}

  @spec collect_errors(Changeset.t()) :: errors()
  def collect_errors(changeset) do
    Changeset.traverse_errors(changeset, &format_error_message/1)
  end

  defp try_fallback_extraction(text) do
    case extract_from_code_fence(text) do
      {:ok, params} when is_map(params) ->
        {:ok, params}

      _ ->
        case extract_from_braces(text) do
          {:ok, params} when is_map(params) -> {:ok, params}
          _ -> {:error, %{json: ["failed to extract valid JSON from response text"]}}
        end
    end
  end

  defp extract_from_code_fence(text) do
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)```/s, text) do
      [_, content] -> Jason.decode(String.trim(content))
      _ -> {:error, :no_code_fence}
    end
  end

  defp extract_from_braces(text) do
    with {:ok, first} <- find_char(text, "{"),
         {:ok, last} <- find_last_char(text, "}"),
         true <- first < last do
      text |> String.slice(first..last) |> Jason.decode()
    else
      _ -> {:error, :no_braces}
    end
  end

  defp find_char(text, char) do
    case :binary.match(text, char) do
      {pos, _} -> {:ok, pos}
      :nomatch -> {:error, :not_found}
    end
  end

  defp find_last_char(text, char) do
    # :binary.match does not support reverse scope — search from the end manually
    case String.reverse(text) |> :binary.match(String.reverse(char)) do
      {rev_pos, _} -> {:ok, byte_size(text) - rev_pos - byte_size(char)}
      :nomatch -> {:error, :not_found}
    end
  end

  defp format_error_message({msg, opts}) do
    opts = Enum.into(opts, %{}, fn {k, v} -> {k, v} end)
    if opts[:count], do: String.replace(msg, "%{count}", to_string(opts[:count])), else: msg
  end

  defp format_error_message(msg) when is_binary(msg), do: msg
  defp format_error_message(other), do: inspect(other)
end
