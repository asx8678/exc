defmodule CodePuppyControl.Config.TUI do
  @moduledoc """
  TUI theme, color, and display configuration.

  Manages banner colors, diff highlight colors, display suppression flags,
  and other UI-related settings from `puppy.cfg`.

  ## Config keys in `puppy.cfg`

  - `banner_color_<name>` — per-banner background color
  - `highlight_addition_color` — diff addition color
  - `highlight_deletion_color` — diff deletion color
  - `suppress_thinking_messages` — hide thinking/reasoning messages
  - `suppress_informational_messages` — hide info/success/warning messages
  - `grep_output_verbose` — show full grep output vs. concise
  - `diff_context_lines` — context lines for diff display (default 6)
  """

  alias CodePuppyControl.Config.Loader

  # ── Default banner colors ───────────────────────────────────────────────

  @default_banner_colors %{
    "thinking" => "deep_sky_blue4",
    "agent_response" => "medium_purple4",
    "shell_command" => "dark_orange3",
    "read_file" => "steel_blue",
    "edit_file" => "dark_goldenrod",
    "create_file" => "dark_goldenrod",
    "replace_in_file" => "dark_goldenrod",
    "delete_snippet" => "dark_goldenrod",
    "grep" => "grey37",
    "directory_listing" => "dodger_blue2",
    "agent_reasoning" => "dark_violet",
    "invoke_agent" => "deep_pink4",
    "subagent_response" => "sea_green3",
    "list_agents" => "dark_slate_gray3",
    "universal_constructor" => "dark_cyan",
    "terminal_tool" => "dark_goldenrod",
    "mcp_tool_call" => "dark_cyan",
    "shell_passthrough" => "medium_sea_green"
  }

  @doc """
  Get the color for a specific banner. Falls back to the default palette.
  """
  @spec banner_color(String.t()) :: String.t()
  def banner_color(name) do
    Loader.get_value("banner_color_#{name}") ||
      Map.get(@default_banner_colors, name, "blue")
  end

  @doc """
  Set the color for a specific banner.
  """
  @spec set_banner_color(String.t(), String.t()) :: :ok
  def set_banner_color(name, color) when is_binary(color) do
    CodePuppyControl.Config.Writer.set_value("banner_color_#{name}", color)
  end

  @doc """
  Return all banner colors (configured + defaults) as a map.
  """
  @spec all_banner_colors() :: %{String.t() => String.t()}
  def all_banner_colors do
    Map.new(@default_banner_colors, fn {name, default} ->
      {name, Loader.get_value("banner_color_#{name}") || default}
    end)
  end

  @doc """
  Reset a single banner color to its default.
  """
  @spec reset_banner_color(String.t()) :: :ok
  def reset_banner_color(name) do
    default = Map.get(@default_banner_colors, name, "blue")
    set_banner_color(name, default)
  end

  @doc """
  Reset all banner colors to defaults.
  """
  @spec reset_all_banner_colors() :: :ok
  def reset_all_banner_colors do
    Enum.each(@default_banner_colors, fn {name, color} ->
      set_banner_color(name, color)
    end)
  end

  @doc """
  Return the default banner colors map (read-only).
  """
  @spec default_banner_colors() :: %{String.t() => String.t()}
  def default_banner_colors, do: @default_banner_colors

  # ── Diff colors ─────────────────────────────────────────────────────────

  @doc "Return diff addition color (default `\"#0b1f0b\"`)."
  @spec diff_addition_color() :: String.t()
  def diff_addition_color do
    Loader.get_value("highlight_addition_color") || "#0b1f0b"
  end

  @doc "Set diff addition color."
  @spec set_diff_addition_color(String.t()) :: :ok
  def set_diff_addition_color(color) do
    CodePuppyControl.Config.Writer.set_value("highlight_addition_color", color)
  end

  @doc "Return diff deletion color (default `\"#390e1a\"`)."
  @spec diff_deletion_color() :: String.t()
  def diff_deletion_color do
    Loader.get_value("highlight_deletion_color") || "#390e1a"
  end

  @doc "Set diff deletion color."
  @spec set_diff_deletion_color(String.t()) :: :ok
  def set_diff_deletion_color(color) do
    CodePuppyControl.Config.Writer.set_value("highlight_deletion_color", color)
  end

  # ── Display flags ───────────────────────────────────────────────────────

  @doc "Return `true` if thinking messages are suppressed (default `false`)."
  @spec suppress_thinking?() :: boolean()
  def suppress_thinking?, do: truthy?("suppress_thinking_messages")

  @doc "Set suppress_thinking_messages."
  @spec set_suppress_thinking(boolean()) :: :ok
  def set_suppress_thinking(enabled) do
    CodePuppyControl.Config.Writer.set_value("suppress_thinking_messages", bool_str(enabled))
  end

  @doc "Return `true` if informational messages are suppressed (default `false`)."
  @spec suppress_informational?() :: boolean()
  def suppress_informational?, do: truthy?("suppress_informational_messages")

  @doc "Set suppress_informational_messages."
  @spec set_suppress_informational(boolean()) :: :ok
  def set_suppress_informational(enabled) do
    CodePuppyControl.Config.Writer.set_value("suppress_informational_messages", bool_str(enabled))
  end

  @doc "Return `true` if verbose grep output is enabled (default `false`)."
  @spec grep_output_verbose?() :: boolean()
  def grep_output_verbose?, do: truthy?("grep_output_verbose")

  @doc "Return diff context lines (default `6`, range `0–50`)."
  @spec diff_context_lines() :: non_neg_integer()
  def diff_context_lines do
    case Loader.get_value("diff_context_lines") do
      nil ->
        6

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 and n <= 50 -> n
          _ -> 6
        end
    end
  end

  # ── Auto-save ───────────────────────────────────────────────────────────

  @doc "Return `true` if auto-save is enabled (default `true`)."
  @spec auto_save_session?() :: boolean()
  def auto_save_session?, do: truthy?("auto_save_session", true)

  @doc "Set auto_save_session."
  @spec set_auto_save_session(boolean()) :: :ok
  def set_auto_save_session(enabled) do
    CodePuppyControl.Config.Writer.set_value("auto_save_session", bool_str(enabled))
  end

  @doc "Return max saved sessions (default `20`)."
  @spec max_saved_sessions() :: non_neg_integer()
  def max_saved_sessions do
    case Loader.get_value("max_saved_sessions") do
      nil ->
        20

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> 20
        end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @truthy_values MapSet.new(["1", "true", "yes", "on"])

  defp truthy?(key, default \\ false) do
    case Loader.get_value(key) do
      nil -> default
      val -> String.downcase(String.trim(val)) in @truthy_values
    end
  end

  defp bool_str(true), do: "true"
  defp bool_str(false), do: "false"
end
