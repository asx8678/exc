defmodule CodePuppyControl.TUI.Theme do
  @moduledoc """
  Centralised brand palette and style constants for the Code Puppy TUI.

  All TUI modules should reference this module for colours, icons, and
  spacing — never hard-code values. This keeps the visual identity
  consistent and makes rebranding or theming a single-point change.

  ## Colour Palette

  The palette is divided into semantic categories. Each colour is an
  atom recognised by `Owl.Data.tag/2` (ANSI 16-colour or 256-colour).

  ## Usage

      # Brand colour
      Owl.Data.tag("Welcome!", Theme.color(:brand))

      # Status colours
      Owl.Data.tag("✔ Success", Theme.color(:success))
      Owl.Data.tag("✖ Error", Theme.color(:error))

      # Icons
      icon = Theme.icon(:puppy)   #=> "🐶"
  """

  alias Owl.Data

  # ── Semantic Colour Map ──────────────────────────────────────────────────

  @colors %{
    # Brand
    brand: :cyan,
    brand_bright: :bright_cyan,
    # Status
    success: :green,
    error: :red,
    warning: :yellow,
    info: :blue,
    # Content
    thinking: :faint,
    assistant: :green,
    user: :blue,
    system: :yellow,
    # UI chrome
    header: :bright_cyan,
    footer: :faint,
    border: :cyan,
    dim: :faint,
    # Data
    keyword: :magenta,
    string: :green,
    comment: :faint,
    number: :yellow,
    function: :cyan,
    type: :blue,
    atom: :cyan,
    # Tool banners
    tool_read: :cyan,
    tool_write: :green,
    tool_edit: :yellow,
    tool_delete: :red,
    tool_search: :magenta,
    tool_shell: :blue,
    tool_agent: :blue,
    tool_mcp: :magenta
  }

  # ── Icon Map ────────────────────────────────────────────────────────────

  @icons %{
    puppy: "🐶",
    paw: "🐾",
    thinking: "⚡",
    streaming: "⏳",
    idle: "🐾",
    success: "✔",
    error: "✖",
    warning: "⚠",
    info: "ℹ",
    config: "⚙️",
    help: "❓",
    chat: "💬",
    file_read: "📖",
    file_write: "✏️",
    file_edit: "🔧",
    file_delete: "🗑️",
    folder: "📁",
    search: "🔍",
    shell: "💻",
    agent: "🤖",
    mcp: "🔌",
    star: "★",
    arrow: "→"
  }

  # ── Spacing / Layout Constants ──────────────────────────────────────────

  @min_box_width 60
  @default_bar_width 40
  @section_separator "─"

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Return the ANSI colour atom for a semantic key.

  Falls back to `:default_color` for unknown keys.

  ## Examples

      iex> Theme.color(:brand)
      :cyan

      iex> Theme.color(:unknown_key)
      :default_color
  """
  @spec color(atom()) :: atom()
  def color(key) when is_atom(key) do
    Map.get(@colors, key, :default_color)
  end

  @doc """
  Return all semantic colour mappings (read-only).
  """
  @spec all_colors() :: %{atom() => atom()}
  def all_colors, do: @colors

  @doc """
  Return the icon string for a semantic key.

  Falls back to `"•"` for unknown keys.

  ## Examples

      iex> Theme.icon(:puppy)
      "🐶"
  """
  @spec icon(atom()) :: String.t()
  def icon(key) when is_atom(key) do
    Map.get(@icons, key, "•")
  end

  @doc """
  Return all icon mappings (read-only).
  """
  @spec all_icons() :: %{atom() => String.t()}
  def all_icons, do: @icons

  @doc """
  Tag text with a semantic colour.

  Shorthand for `Owl.Data.tag(text, Theme.color(key))`.

  ## Examples

      iex> Theme.tag("Hello", :brand)
      Owl.Data.tag("Hello", :cyan)
  """
  @spec tag(String.t() | iodata(), atom()) :: Data.t()
  def tag(text, key) when is_atom(key) do
    Data.tag(text, color(key))
  end

  @doc """
  Tag text with a brand colour and optional icon prefix.

  ## Examples

      iex> Theme.brand("Welcome")
      Owl.Data.tag("🐶 Welcome", :cyan)
  """
  @spec brand(String.t()) :: Data.t()
  def brand(text) do
    Data.tag("#{icon(:puppy)} #{text}", color(:brand))
  end

  @doc """
  Create a section separator line.

  ## Options

    * `:width` — line width in columns (default: `@min_box_width`)
    * `:style` — `:faint` (default), `:cyan`, or any colour atom

  ## Examples

      iex> Theme.separator()
      Owl.Data.tag("────────────────────────────────────────────────────────────", :faint)
  """
  @spec separator(keyword()) :: Data.t()
  def separator(opts \\ []) do
    width = Keyword.get(opts, :width, @min_box_width)
    style = Keyword.get(opts, :style, :faint)
    Data.tag(String.duplicate(@section_separator, width), style)
  end

  @doc """
  Return the minimum box width for Owl.Box layouts.
  """
  @spec min_box_width() :: non_neg_integer()
  def min_box_width, do: @min_box_width

  @doc """
  Return the default progress bar width.
  """
  @spec default_bar_width() :: non_neg_integer()
  def default_bar_width, do: @default_bar_width

  @doc """
  Render a tool banner header line.

  Selects icon and colour based on the tool name, matching the
  Python StreamRenderer's `TOOL_BANNER_MAP` convention.

  ## Examples

      iex> Theme.tool_banner("read_file")
      # Returns Owl.Data tagged content with 📖 and cyan
  """
  @spec tool_banner(String.t()) :: Data.t()
  def tool_banner(tool_name) when is_binary(tool_name) do
    {label, color_key, icon_key} = tool_banner_spec(tool_name)
    icon = icon(icon_key)

    Data.tag(" #{icon} #{label} ", [:white, bg_color(color(color_key))])
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp tool_banner_spec("read_file"), do: {"READ FILE", :tool_read, :file_read}
  defp tool_banner_spec("create_file"), do: {"CREATE FILE", :tool_write, :file_write}
  defp tool_banner_spec("write_file"), do: {"WRITE FILE", :tool_write, :file_write}
  defp tool_banner_spec("replace_in_file"), do: {"EDIT FILE", :tool_edit, :file_edit}
  defp tool_banner_spec("delete_file"), do: {"DELETE FILE", :tool_delete, :file_delete}
  defp tool_banner_spec("delete_snippet"), do: {"DELETE SNIPPET", :tool_edit, :file_edit}
  defp tool_banner_spec("list_files"), do: {"LIST FILES", :tool_read, :folder}
  defp tool_banner_spec("grep"), do: {"GREP", :tool_search, :search}
  defp tool_banner_spec("run_shell_command"), do: {"SHELL", :tool_shell, :shell}
  defp tool_banner_spec("agent_run"), do: {"AGENT", :tool_agent, :agent}
  defp tool_banner_spec("mcp_tool_call"), do: {"MCP TOOL", :tool_mcp, :mcp}
  defp tool_banner_spec(name), do: {String.upcase(name), :info, :file_edit}

  # Map foreground colours to Owl background colour atoms
  defp bg_color(:cyan), do: :cyan_background
  defp bg_color(:green), do: :green_background
  defp bg_color(:yellow), do: :yellow_background
  defp bg_color(:red), do: :red_background
  defp bg_color(:blue), do: :blue_background
  defp bg_color(:magenta), do: :magenta_background
  defp bg_color(_), do: :blue_background
end
