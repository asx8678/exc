defmodule CodePuppyControl.Tools.UniversalConstructor do
  @moduledoc """
  Universal Constructor - Dynamic tool creation and management for Elixir.

  This module provides the universal_constructor tool that enables users to create,
  manage, and call custom Elixir tools dynamically during a session.

  ## Actions

  - `list` - List all available UC tools
  - `call` - Execute a specific UC tool with arguments
  - `create` - Create a new UC tool from Elixir code
  - `update` - Modify an existing UC tool
  - `info` - Get detailed info about a specific tool

  ## Architecture

  The Universal Constructor maintains a registry of tools stored in:
  `~/.code_puppy/plugins/universal_constructor/`

  Each tool is an Elixir module (.ex file) containing:
  - @uc_tool metadata attribute
  - A public function (typically named after the tool, or `run/1`)

  ## Examples

      # List all tools
      UniversalConstructor.run(action: "list")

      # Create a new tool
      UniversalConstructor.run(
        action: "create",
        tool_name: "hello",
        elixir_code: ~s(defmodule HelloTool do
        @uc_tool %{name: "hello", description: "Says hello"}
        def run(name), do: "Hello, \#{name}!"
      end)
      )

      # Call a tool
      UniversalConstructor.run(action: "call", tool_name: "hello", tool_args: %{"name" => "World"})
  """

  require Logger

  alias CodePuppyControl.Tools.UniversalConstructor.Models
  alias CodePuppyControl.Tools.UniversalConstructor.Registry
  alias CodePuppyControl.Tools.UniversalConstructor.Validator
  alias CodePuppyControl.Tools.UniversalConstructor.CreateAction

  @default_timeout 30_000

  @typedoc """
  Supported UC actions
  """
  @type action :: :list | :call | :create | :update | :info

  @typedoc """
  Options for run/1
  """
  @type run_opts :: [
          action: action() | String.t(),
          tool_name: String.t() | nil,
          tool_args: map() | nil,
          elixir_code: String.t() | nil,
          description: String.t() | nil
        ]

  @doc """
  Runs a Universal Constructor action.

  ## Options

    * `:action` - The action to perform: "list", "call", "create", "update", "info"
    * `:tool_name` - Name of tool (for call/update/info). Supports "namespace.name" format
    * `:tool_args` - Arguments to pass when calling a tool
    * `:elixir_code` - Elixir source code for the tool (for create/update)
    * `:description` - Human-readable description (for create)

  ## Examples

      # List all tools
      iex> UniversalConstructor.run(action: "list")
      %{action: "list", success: true, list_result: %{...}}

      # Create a tool
      iex> UniversalConstructor.run(
      ...>   action: "create",
      ...>   tool_name: "greeter",
      ...>   elixir_code: "...",
      ...>   description: "A greeting tool"
      ...> )
      %{action: "create", success: true, create_result: %{...}}

  """
  @spec run(run_opts()) :: map()
  def run(opts \\ []) do
    action = normalize_action(Keyword.get(opts, :action, "list"))
    tool_name = Keyword.get(opts, :tool_name)
    tool_args = Keyword.get(opts, :tool_args, %{})
    elixir_code = Keyword.get(opts, :elixir_code)
    description = Keyword.get(opts, :description)

    # Ensure tools directory exists
    _ = Registry.ensure_tools_dir()

    result =
      case action do
        :list ->
          handle_list_action()

        :call ->
          handle_call_action(tool_name, tool_args)

        :create ->
          handle_create_action(tool_name, elixir_code, description)

        :update ->
          handle_update_action(tool_name, elixir_code)

        :info ->
          handle_info_action(tool_name)

        unknown ->
          build_output(action, false, "Unknown action: #{unknown}")
      end

    # Build summary for any message emission (optional)
    _summary = build_summary(result)

    result
  end

  @doc """
  Formats tool information for display.

  Returns a formatted markdown string suitable for agent consumption.
  """
  @spec format_tools(list(Models.uc_tool_info())) :: String.t()
  def format_tools(tools) when is_list(tools) do
    total_count = length(tools)
    enabled_count = Enum.count(tools, & &1.meta.enabled)

    lines = [
      "## Universal Constructor Tools",
      "",
      "**Total:** #{total_count} tools (#{enabled_count} enabled)",
      ""
    ]

    if total_count == 0 do
      lines =
        lines ++
          [
            "No UC tools found.",
            "",
            "Use `universal_constructor` with `action: \"create\"` to create one!"
          ]

      Enum.join(lines, "\n")
    else
      tool_lines =
        Enum.map(tools, fn tool ->
          status_icon = if tool.meta.enabled, do: "🟢", else: "🔴"

          lines = [
            "### #{status_icon} #{tool.full_name}",
            "- **Description:** #{tool.meta.description}",
            "- **Version:** #{tool.meta.version}",
            "- **Signature:** `#{tool.signature}`",
            "- **Source:** `#{tool.source_path}`"
          ]

          lines =
            if tool.docstring do
              lines ++ ["- **Doc:** #{String.slice(tool.docstring, 0, 100)}..."]
            else
              lines
            end

          lines ++ [""]
        end)

      Enum.join(lines ++ Enum.concat(tool_lines), "\n")
    end
  end

  @doc """
  Formats a single tool's details for display.
  """
  @spec format_tool(Models.uc_tool_info(), String.t() | nil) :: String.t()
  def format_tool(tool, source_code \\ nil) do
    meta = tool.meta

    created_line = if meta.created_at, do: "- **Created:** #{meta.created_at}", else: nil

    lines =
      [
        "## Tool: #{tool.full_name}",
        "",
        "### Metadata",
        "- **Name:** #{meta.name}",
        "- **Namespace:** #{if meta.namespace == "", do: "(none)", else: meta.namespace}",
        "- **Description:** #{meta.description}",
        "- **Enabled:** #{if meta.enabled, do: "Yes", else: "No"}",
        "- **Version:** #{meta.version}",
        "- **Author:** #{meta.author}",
        created_line,
        "",
        "### Implementation",
        "- **Function:** `#{tool.function_name}`",
        "- **Signature:** `#{tool.signature}`",
        "- **Source Path:** `#{tool.source_path}`"
      ]
      |> Enum.reject(&is_nil/1)

    lines =
      if tool.docstring do
        lines ++ ["", "### Documentation", "```", tool.docstring, "```"]
      else
        lines
      end

    lines =
      if source_code do
        preview = Validator.generate_preview(source_code, 30)
        lines ++ ["", "### Source Code", "```elixir", preview, "```"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  # ============================================================================
  # Private Action Handlers
  # ============================================================================

  defp handle_list_action do
    tools = Registry.list_tools(include_disabled: true)

    list_output =
      Models.uc_list_output(
        tools: tools,
        total_count: length(tools),
        enabled_count: Enum.count(tools, & &1.meta.enabled)
      )

    build_output("list", true, nil, list_result: list_output)
  end

  defp handle_call_action(nil, _) do
    build_output("call", false, "tool_name is required for call action")
  end

  defp handle_call_action(tool_name, tool_args) do
    tool = Registry.get_tool(tool_name)

    cond do
      is_nil(tool) ->
        build_output("call", false, "Tool '#{tool_name}' not found")

      not tool.meta.enabled ->
        build_output("call", false, "Tool '#{tool_name}' is disabled")

      true ->
        # Get the tool function
        func_info = Registry.get_tool_function(tool_name)

        if is_nil(func_info) do
          build_output("call", false, "Could not load function for '#{tool_name}'")
        else
          {module, func_name} = func_info

          # Read source for preview
          source_preview =
            if File.exists?(tool.source_path) do
              case File.read(tool.source_path) do
                {:ok, code} -> Validator.generate_preview(code)
                _ -> nil
              end
            else
              nil
            end

          # Execute with timeout
          start_time = System.monotonic_time()

          try do
            args = normalize_args(tool_args)

            # Run in a task with timeout
            task = Task.async(fn -> apply(module, func_name, [args]) end)

            result = Task.await(task, @default_timeout)
            end_time = System.monotonic_time()
            elapsed = System.convert_time_unit(end_time - start_time, :native, :millisecond)

            call_output =
              Models.uc_call_output(
                success: true,
                tool_name: tool_name,
                result: result,
                execution_time: elapsed / 1000.0,
                source_preview: source_preview
              )

            build_output("call", true, nil, call_result: call_output)
          catch
            :exit, {:timeout, _} ->
              build_output(
                "call",
                false,
                "Tool '#{tool_name}' timed out after #{@default_timeout}ms"
              )

            kind, error ->
              build_output("call", false, "Tool execution failed (#{kind}): #{inspect(error)}")
          end
        end
    end
  end

  defp handle_create_action(tool_name, elixir_code, description) do
    CreateAction.execute(tool_name, elixir_code, description)
  end

  defp handle_update_action(nil, _) do
    build_output("update", false, "tool_name is required for update action")
  end

  defp handle_update_action(_, nil) do
    build_output("update", false, "elixir_code is required for update action")
  end

  defp handle_update_action(tool_name, elixir_code) do
    tool = Registry.get_tool(tool_name)

    if is_nil(tool) do
      build_output("update", false, "Tool '#{tool_name}' not found")
    else
      source_path = tool.source_path

      if not File.exists?(source_path) do
        build_output("update", false, "Tool has no source path or file does not exist")
      else
        # Validate new code syntax
        syntax = Validator.validate_syntax(elixir_code)

        if not syntax.valid do
          build_output(
            "update",
            false,
            "Syntax error in new code: #{Enum.join(syntax.errors, "; ")}"
          )
        else
          # Validate @uc_tool exists
          case Validator.extract_uc_tool_meta(elixir_code) do
            {:ok, _} ->
              # Write updated code
              case File.write(source_path, elixir_code) do
                :ok ->
                  # Read back for preview
                  preview = Validator.generate_preview(elixir_code)

                  # Reload registry
                  _count = Registry.reload()

                  changes = ["Replaced source code"]

                  update_output =
                    Models.uc_update_output(
                      success: true,
                      tool_name: tool_name,
                      source_path: source_path,
                      preview: preview,
                      changes_applied: changes
                    )

                  build_output("update", true, nil, update_result: update_output)

                {:error, reason} ->
                  build_output("update", false, "Failed to write file: #{inspect(reason)}")
              end

            {:error, reason} ->
              build_output("update", false, "New code must contain a valid @uc_tool: #{reason}")
          end
        end
      end
    end
  end

  defp handle_info_action(nil) do
    build_output("info", false, "tool_name is required for info action")
  end

  defp handle_info_action(tool_name) do
    tool = Registry.get_tool(tool_name)

    if is_nil(tool) do
      build_output("info", false, "Tool '#{tool_name}' not found")
    else
      # Read source code
      source_code =
        if File.exists?(tool.source_path) do
          case File.read(tool.source_path) do
            {:ok, code} -> code
            _ -> "[Could not read source]"
          end
        else
          "[Source file not found]"
        end

      info_output =
        Models.uc_info_output(
          success: true,
          tool: tool,
          source_code: source_code
        )

      build_output("info", true, nil, info_result: info_output)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_action(action) when is_atom(action), do: action

  defp normalize_action(action) when is_binary(action) do
    case String.downcase(action) do
      "list" -> :list
      "call" -> :call
      "create" -> :create
      "update" -> :update
      "info" -> :info
      other -> other
    end
  end

  defp normalize_action(_), do: :list

  defp normalize_args(args) when is_map(args), do: args

  defp normalize_args(args) when is_binary(args) do
    # Try to parse JSON string
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp normalize_args(_), do: %{}

  defp build_output(action, success, error, extra \\ []) do
    base = %{
      action: to_string(action),
      success: success,
      error: error,
      list_result: nil,
      call_result: nil,
      create_result: nil,
      update_result: nil,
      info_result: nil
    }

    Enum.reduce(extra, base, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp build_summary(result) do
    cond do
      not result.success ->
        result.error || "Operation failed"

      result[:list_result] ->
        lr = result.list_result
        "Found #{lr.enabled_count} enabled tools (of #{lr.total_count} total)"

      result[:call_result] ->
        cr = result.call_result
        exec_time = cr.execution_time || 0
        "Executed in #{:erlang.float_to_binary(exec_time, decimals: 2)}s"

      result[:create_result] ->
        "Created #{result.create_result.tool_name}"

      result[:update_result] ->
        "Updated #{result.update_result.tool_name}"

      result[:info_result] ->
        if result.info_result.tool do
          "Info for #{result.info_result.tool.full_name}"
        else
          "Info lookup completed"
        end

      true ->
        "Operation completed"
    end
  end
end
