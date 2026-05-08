defmodule CodePuppyControl.Tools.UniversalConstructor.Models do
  @moduledoc """
  Data models for the Universal Constructor tool system.

  Defines structs for tool metadata, tool information, and operation results.
  These models mirror the Python Pydantic models but adapted for Elixir.
  """

  @type tool_meta :: %{
          name: String.t(),
          namespace: String.t(),
          description: String.t(),
          enabled: boolean(),
          version: String.t(),
          author: String.t(),
          created_at: String.t() | nil
        }

  @type uc_tool_info :: %{
          meta: tool_meta(),
          signature: String.t(),
          source_path: String.t(),
          function_name: String.t(),
          docstring: String.t() | nil,
          full_name: String.t()
        }

  @type uc_list_output :: %{
          tools: list(uc_tool_info()),
          total_count: non_neg_integer(),
          enabled_count: non_neg_integer(),
          error: String.t() | nil
        }

  @type uc_call_output :: %{
          success: boolean(),
          tool_name: String.t(),
          result: any(),
          error: String.t() | nil,
          execution_time: float() | nil,
          source_preview: String.t() | nil
        }

  @type uc_create_output :: %{
          success: boolean(),
          tool_name: String.t(),
          source_path: String.t() | nil,
          preview: String.t() | nil,
          error: String.t() | nil,
          validation_warnings: list(String.t())
        }

  @type uc_update_output :: %{
          success: boolean(),
          tool_name: String.t(),
          source_path: String.t() | nil,
          preview: String.t() | nil,
          error: String.t() | nil,
          changes_applied: list(String.t())
        }

  @type uc_info_output :: %{
          success: boolean(),
          tool: uc_tool_info() | nil,
          source_code: String.t() | nil,
          error: String.t() | nil
        }

  @doc """
  Builds the full qualified name from namespace and name.
  """
  @spec full_name(String.t(), String.t()) :: String.t()
  def full_name(namespace, name) do
    if namespace != "", do: "#{namespace}.#{name}", else: name
  end

  @doc """
  Creates a ToolMeta map with defaults.
  """
  @spec tool_meta(keyword()) :: tool_meta()
  def tool_meta(attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      name: Keyword.get(attrs, :name, ""),
      namespace: Keyword.get(attrs, :namespace, ""),
      description: Keyword.get(attrs, :description, ""),
      enabled: Keyword.get(attrs, :enabled, true),
      version: Keyword.get(attrs, :version, "1.0.0"),
      author: Keyword.get(attrs, :author, "user"),
      created_at: Keyword.get(attrs, :created_at, now)
    }
  end

  @doc """
  Creates a UCToolInfo map.
  """
  @spec uc_tool_info(keyword()) :: uc_tool_info()
  def uc_tool_info(attrs \\ []) do
    meta = Keyword.get(attrs, :meta, tool_meta())

    %{
      meta: meta,
      signature: Keyword.get(attrs, :signature, ""),
      source_path: Keyword.get(attrs, :source_path, ""),
      function_name: Keyword.get(attrs, :function_name, ""),
      docstring: Keyword.get(attrs, :docstring, nil),
      full_name: full_name(meta.namespace, meta.name)
    }
  end

  @doc """
  Creates a UCListOutput map.
  """
  @spec uc_list_output(keyword()) :: uc_list_output()
  def uc_list_output(attrs \\ []) do
    tools = Keyword.get(attrs, :tools, [])

    %{
      tools: tools,
      total_count: Keyword.get(attrs, :total_count, length(tools)),
      enabled_count: Keyword.get(attrs, :enabled_count, count_enabled(tools)),
      error: Keyword.get(attrs, :error, nil)
    }
  end

  @doc """
  Creates a UCCallOutput map.
  """
  @spec uc_call_output(keyword()) :: uc_call_output()
  def uc_call_output(attrs \\ []) do
    %{
      success: Keyword.get(attrs, :success, true),
      tool_name: Keyword.get(attrs, :tool_name, ""),
      result: Keyword.get(attrs, :result, nil),
      error: Keyword.get(attrs, :error, nil),
      execution_time: Keyword.get(attrs, :execution_time, nil),
      source_preview: Keyword.get(attrs, :source_preview, nil)
    }
  end

  @doc """
  Creates a UCCreateOutput map.
  """
  @spec uc_create_output(keyword()) :: uc_create_output()
  def uc_create_output(attrs \\ []) do
    %{
      success: Keyword.get(attrs, :success, true),
      tool_name: Keyword.get(attrs, :tool_name, ""),
      source_path: Keyword.get(attrs, :source_path, nil),
      preview: Keyword.get(attrs, :preview, nil),
      error: Keyword.get(attrs, :error, nil),
      validation_warnings: Keyword.get(attrs, :validation_warnings, [])
    }
  end

  @doc """
  Creates a UCUpdateOutput map.
  """
  @spec uc_update_output(keyword()) :: uc_update_output()
  def uc_update_output(attrs \\ []) do
    %{
      success: Keyword.get(attrs, :success, true),
      tool_name: Keyword.get(attrs, :tool_name, ""),
      source_path: Keyword.get(attrs, :source_path, nil),
      preview: Keyword.get(attrs, :preview, nil),
      error: Keyword.get(attrs, :error, nil),
      changes_applied: Keyword.get(attrs, :changes_applied, [])
    }
  end

  @doc """
  Creates a UCInfoOutput map.
  """
  @spec uc_info_output(keyword()) :: uc_info_output()
  def uc_info_output(attrs \\ []) do
    %{
      success: Keyword.get(attrs, :success, true),
      tool: Keyword.get(attrs, :tool, nil),
      source_code: Keyword.get(attrs, :source_code, nil),
      error: Keyword.get(attrs, :error, nil)
    }
  end

  # Private helpers

  defp count_enabled(tools) do
    Enum.count(tools, fn t -> t.meta.enabled end)
  end
end
