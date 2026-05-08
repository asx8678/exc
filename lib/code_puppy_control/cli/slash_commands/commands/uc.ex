defmodule CodePuppyControl.CLI.SlashCommands.Commands.UC do
  @moduledoc """
  UC slash command: /uc [subcommand] [args].

  Manages Universal Constructor tools from the CLI. Provides a simplified
  text-based interface (not the full TUI from the Python version).

  Ports the Python `/uc` command from `code_puppy/command_line/uc_menu.py`.

  ## Usage

    /uc — list all UC tools with enabled/disabled status
    /uc toggle <tool_name> — toggle a tool's enabled/disabled status
    /uc info <tool_name> — show tool details (description, source path)
  """

  alias CodePuppyControl.Tools.UniversalConstructor.Registry, as: UCRegistry

  @doc """
  Handles `/uc` — lists all UC tools.

  Handles `/uc toggle <tool_name>` — toggles a tool's enabled flag.

  Handles `/uc info <tool_name>` — shows detailed info for a tool.
  """
  @spec handle_uc(String.t(), any()) :: {:continue, any()}
  def handle_uc(line, state) do
    case extract_args(line) |> String.trim() do
      "" ->
        list_tools()

      args ->
        parts = String.split(args, ~r/\s+/, trim: true)

        case parts do
          ["toggle", tool_name] ->
            toggle_tool(tool_name)

          ["info", tool_name] ->
            show_tool_info(tool_name)

          _more ->
            print_usage()
        end
    end

    {:continue, state}
  end

  # ── Subcommands ──────────────────────────────────────────────────────

  defp list_tools do
    with_uc_registry(fn -> list_tools_impl() end)
  end

  defp list_tools_impl do
    tools = UCRegistry.list_tools(include_disabled: true)
    enabled_count = Enum.count(tools, & &1.meta.enabled)
    total_count = length(tools)

    IO.puts("")

    IO.puts(" #{IO.ANSI.bright()}Universal Constructor Tools#{IO.ANSI.reset()}")

    IO.puts("")

    if total_count == 0 do
      IO.puts(" #{IO.ANSI.yellow()}No UC tools found.#{IO.ANSI.reset()}")

      IO.puts(
        " #{IO.ANSI.faint()}Ask the LLM to create one with universal_constructor!#{IO.ANSI.reset()}"
      )
    else
      IO.puts(
        " #{IO.ANSI.faint()}#{enabled_count} enabled of #{total_count} total#{IO.ANSI.reset()}"
      )

      IO.puts("")

      Enum.each(tools, fn tool ->
        status =
          if tool.meta.enabled do
            "#{IO.ANSI.green()}[on]#{IO.ANSI.reset()}"
          else
            "#{IO.ANSI.red()}[off]#{IO.ANSI.reset()}"
          end

        namespace_tag =
          if tool.meta.namespace != "" do
            " #{IO.ANSI.faint()}(#{tool.meta.namespace})#{IO.ANSI.reset()}"
          else
            ""
          end

        IO.puts(" #{status} #{IO.ANSI.cyan()}#{tool.full_name}#{IO.ANSI.reset()}#{namespace_tag}")
      end)
    end

    IO.puts("")

    IO.puts(
      " #{IO.ANSI.faint()}Use /uc toggle <name> to enable/disable, /uc info <name> for details#{IO.ANSI.reset()}"
    )

    IO.puts("")
  end

  defp toggle_tool(tool_name) do
    with_uc_registry(fn -> toggle_tool_impl(tool_name) end)
  end

  defp toggle_tool_impl(tool_name) do
    tool = UCRegistry.get_tool(tool_name)

    case tool do
      nil ->
        IO.puts(
          IO.ANSI.red() <>
            " Unknown tool: '#{tool_name}'" <> IO.ANSI.reset()
        )

      _tool ->
        source_path = tool.source_path

        case toggle_enabled_in_source(source_path, tool.meta.enabled) do
          :ok ->
            new_enabled = not tool.meta.enabled
            status = if new_enabled, do: "enabled", else: "disabled"

            # Reload the registry so the change is reflected
            UCRegistry.reload()

            IO.puts("")

            IO.puts(
              " Tool '#{IO.ANSI.cyan()}#{tool_name}#{IO.ANSI.reset()}' is now #{IO.ANSI.green()}#{status}#{IO.ANSI.reset()}"
            )

            IO.puts("")

          {:error, reason} ->
            IO.puts(
              IO.ANSI.red() <>
                " Failed to toggle tool: #{reason}" <> IO.ANSI.reset()
            )
        end
    end
  end

  defp show_tool_info(tool_name) do
    with_uc_registry(fn -> show_tool_info_impl(tool_name) end)
  end

  defp show_tool_info_impl(tool_name) do
    tool = UCRegistry.get_tool(tool_name)

    case tool do
      nil ->
        IO.puts(
          IO.ANSI.red() <>
            " Unknown tool: '#{tool_name}'" <> IO.ANSI.reset()
        )

      _tool ->
        meta = tool.meta

        IO.puts("")

        IO.puts(" #{IO.ANSI.bright()}Tool: #{IO.ANSI.cyan()}#{tool.full_name}#{IO.ANSI.reset()}")

        IO.puts("")

        IO.puts(" #{IO.ANSI.bright()}Name:#{IO.ANSI.reset()} #{meta.name}")

        namespace_display =
          if meta.namespace != "", do: meta.namespace, else: "(none)"

        IO.puts(" #{IO.ANSI.bright()}Namespace:#{IO.ANSI.reset()} #{namespace_display}")

        status =
          if meta.enabled do
            "#{IO.ANSI.green()}ENABLED#{IO.ANSI.reset()}"
          else
            "#{IO.ANSI.red()}DISABLED#{IO.ANSI.reset()}"
          end

        IO.puts(" #{IO.ANSI.bright()}Status:#{IO.ANSI.reset()} #{status}")
        IO.puts(" #{IO.ANSI.bright()}Version:#{IO.ANSI.reset()} #{meta.version}")

        if meta.author != "" do
          IO.puts(" #{IO.ANSI.bright()}Author:#{IO.ANSI.reset()} #{meta.author}")
        end

        IO.puts(
          " #{IO.ANSI.bright()}Signature:#{IO.ANSI.reset()} #{IO.ANSI.yellow()}#{tool.signature}#{IO.ANSI.reset()}"
        )

        IO.puts("")

        IO.puts(" #{IO.ANSI.bright()}Description:#{IO.ANSI.reset()}")

        IO.puts(" #{IO.ANSI.faint()}#{meta.description}#{IO.ANSI.reset()}")

        IO.puts("")

        IO.puts(" #{IO.ANSI.bright()}Source:#{IO.ANSI.reset()}")

        IO.puts(" #{IO.ANSI.faint()}#{tool.source_path}#{IO.ANSI.reset()}")

        IO.puts("")
    end
  end

  defp print_usage do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        " Usage: /uc [toggle <name> | info <name>]" <> IO.ANSI.reset()
    )

    IO.puts(" #{IO.ANSI.faint()}Use /uc without arguments to list all tools#{IO.ANSI.reset()}")

    IO.puts("")
  end

  # ── Source File Manipulation ──────────────────────────────────────────

  # Public entry-point for toggle so tests can call it directly without
  # needing a running UC Registry.
  @doc false
  @spec toggle_enabled_in_source(String.t(), boolean()) :: :ok | {:error, String.t()}
  def toggle_enabled_in_source(source_path, current_enabled) do
    case File.read(source_path) do
      {:ok, content} ->
        new_enabled = not current_enabled
        new_value = to_string(new_enabled)

        # Targeted: only replace 'enabled' inside the @uc_tool metadata block.
        # This avoids corrupting other 'enabled:' occurrences in the file.
        #
        # Strategy: find the @uc_tool %{ ... } block, then replace
        # 'enabled: <bool>' only within that block.
        case replace_enabled_in_uc_tool_block(content, new_value) do
          {:ok, new_content} ->
            # Atomic write: write to temp file then rename
            tmp_path = source_path <> ".tmp#{:erlang.unique_integer([:positive])}"

            try do
              case File.write(tmp_path, new_content) do
                :ok ->
                  case File.rename(tmp_path, source_path) do
                    :ok ->
                      :ok

                    {:error, reason} ->
                      File.rm(tmp_path)
                      {:error, "Failed to rename temp file: #{inspect(reason)}"}
                  end

                {:error, reason} ->
                  File.rm(tmp_path)
                  {:error, "Failed to write temp file: #{inspect(reason)}"}
              end
            rescue
              e ->
                File.rm(tmp_path)
                {:error, "Atomic write failed: #{inspect(e)}"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Could not read source file: #{inspect(reason)}"}
    end
  end

  # Replace only the TOP-LEVEL 'enabled' field inside the @uc_tool %{ ... } block.
  # Uses line-by-line parsing with brace-depth and string tracking so that
  # nested maps or string literals containing "enabled:" are never touched.
  #
  # This is the structural fix for : the old regex-based approach
  # (~r/^\s*enabled:\s*(true|false)/m) could match `enabled:` keys inside
  # nested maps or string literals within the block.
  defp replace_enabled_in_uc_tool_block(content, new_value) do
    case Regex.run(~r/@uc_tool\s+%\{/, content, return: :index) do
      [{block_start, match_len}] ->
        map_open_end = block_start + match_len

        case find_closing_brace(content, map_open_end) do
          {:ok, closing_pos} ->
            before_block = binary_part(content, 0, block_start)
            block_content = binary_part(content, block_start, closing_pos - block_start + 1)

            after_block =
              binary_part(content, closing_pos + 1, byte_size(content) - closing_pos - 1)

            case replace_top_level_enabled_in_block(block_content, new_value) do
              {:ok, new_block} ->
                {:ok, before_block <> new_block <> after_block}

              {:error, reason} ->
                {:error, reason}
            end

          :error ->
            {:error, "Could not find closing brace for @uc_tool block"}
        end

      nil ->
        {:error, "Could not find @uc_tool attribute"}
    end
  end

  # ── Structural replacement helpers ──────────────────────────

  # Split the block into lines, walk them tracking brace-depth and string
  # state, and replace ONLY the first `enabled:` that sits at depth 1
  # (the top-level map body) and outside any string literal.
  defp replace_top_level_enabled_in_block(block_content, new_value) do
    lines = String.split(block_content, "\n")

    {modified_lines, replaced?} =
      walk_lines_for_enabled(
        lines,
        new_value,
        _replaced? = false,
        _in_string? = false,
        _depth = 0
      )

    if replaced? do
      {:ok, Enum.join(modified_lines, "\n")}
    else
      {:error, "Could not find top-level 'enabled:' field in @uc_tool"}
    end
  end

  defp walk_lines_for_enabled([], _new_value, replaced?, _in_string?, _depth) do
    {[], replaced?}
  end

  defp walk_lines_for_enabled([line | rest], new_value, replaced?, in_string?, depth) do
    {next_in_string, next_depth} = scan_line_for_depth(line, in_string?, depth)

    # A top-level key lives at depth 1 (inside the outermost %{...}).
    # We must NOT be inside a string, and we must not have replaced already.
    should_replace =
      not replaced? and
        not in_string? and
        next_depth == 1 and
        line =~ ~r/^\s*enabled:\s*(true|false)/

    new_line =
      if should_replace do
        Regex.replace(~r/(^\s*enabled:\s*)(true|false)/, line, "\\1#{new_value}")
      else
        line
      end

    {rest_lines, final_replaced?} =
      walk_lines_for_enabled(
        rest,
        new_value,
        should_replace or replaced?,
        next_in_string,
        next_depth
      )

    {[new_line | rest_lines], final_replaced?}
  end

  # Character-level scanner that tracks whether we are inside a double-quoted
  # string and the current brace nesting depth. Respects escaped quotes (\")
  # so that `"foo\"bar"` is treated as one continuous string.
  defp scan_line_for_depth(line, in_string?, depth) do
    line
    |> String.graphemes()
    |> Enum.reduce({in_string?, depth, _escaped? = false}, fn
      # Backslash outside escape: marks next char as escaped
      "\\", {str, d, false} ->
        {str, d, true}

      # Escaped quote inside a string: don't toggle
      "\"", {str, d, true} ->
        {str, d, false}

      # Unescaped quote: toggle string state
      "\"", {str, d, false} ->
        {not str, d, false}

      # Opening brace outside a string: increment depth
      "{", {false = _str, d, _esc} ->
        {false, d + 1, false}

      # Closing brace outside a string: decrement depth
      "}", {false = _str, d, _esc} ->
        {false, d - 1, false}

      # Any other character: clear the escape flag
      _char, {str, d, _esc} ->
        {str, d, false}
    end)
    |> then(fn {str, d, _} -> {str, d} end)
  end

  # Find the position of the closing '}' for a map that starts at `from_pos`.
  # Tracks brace depth, respecting string literals to avoid false matches.
  defp find_closing_brace(content, from_pos) do
    find_closing_brace(content, from_pos, 1, 0)
  end

  defp find_closing_brace(_content, pos, 0, _string_depth) when pos > 0 do
    # We've closed the opening brace — return position of the closing '}'
    {:ok, pos - 1}
  end

  defp find_closing_brace(content, pos, depth, string_depth) when pos <= byte_size(content) do
    case :binary.at(content, pos) do
      ?\" when string_depth == 0 ->
        find_closing_brace(content, pos + 1, depth, 1)

      ?\" when string_depth == 1 ->
        # Check for escaped quote
        if pos > 0 and :binary.at(content, pos - 1) == ?\\ do
          find_closing_brace(content, pos + 1, depth, 1)
        else
          find_closing_brace(content, pos + 1, depth, 0)
        end

      ?{ when string_depth == 0 ->
        find_closing_brace(content, pos + 1, depth + 1, 0)

      ?} when string_depth == 0 ->
        find_closing_brace(content, pos + 1, depth - 1, 0)

      _ ->
        find_closing_brace(content, pos + 1, depth, string_depth)
    end
  end

  defp find_closing_brace(_content, _pos, _depth, _string_depth) do
    :error
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  @spec extract_args(String.t()) :: String.t()
  defp extract_args("/" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [_name] -> ""
      [_name, args] -> args
    end
  end

  defp extract_args(_line), do: ""

  # Graceful fallback when the UC Registry GenServer is not running.
  # Prevents crashes from calling a non-existent process.
  defp with_uc_registry(fun) do
    case Process.whereis(UCRegistry) do
      nil ->
        IO.puts(
          IO.ANSI.red() <>
            " Universal Constructor registry is not running" <> IO.ANSI.reset()
        )

      _pid ->
        fun.()
    end
  end
end
