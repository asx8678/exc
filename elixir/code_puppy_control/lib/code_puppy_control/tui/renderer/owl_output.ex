defmodule CodePuppyControl.TUI.Renderer.OwlOutput do
  @moduledoc """
  Owl terminal output helpers for the TUI Renderer.

  Implements the `TUI.Output` behaviour, providing safe Owl.IO.puts,
  banner rendering, color mapping, and spinner lifecycle management.
  All functions are pure (no GenServer state) — the main Renderer
  GenServer threads state through these as needed.

  This module can be swapped out for a test mock or alternative
  terminal backend per ADR-007 (code_puppy-057.3).
  """

  @behaviour CodePuppyControl.TUI.Output

  require Logger

  # Spinner frame rate (ms)
  @spinner_refresh_ms 100

  # Puppy-themed loading messages (mirroring Python StreamRenderer)
  @loading_messages [
    "Sniffing around...",
    "Wagging tail...",
    "Digging up results...",
    "Chewing on it...",
    "Puppy pondering...",
    "Bounding through data...",
    "Howling at the code..."
  ]

  # Banner style map: config_name → {label, color, icon}
  # Mirrors the Python TOOL_BANNER_MAP
  @tool_banner_styles %{
    "read_file" => {"READ FILE", :cyan, "📖"},
    "write_file" => {"WRITE FILE", :green, "✏️"},
    "replace_in_file" => {"EDIT FILE", :yellow, "🔧"},
    "delete_file" => {"DELETE FILE", :red, "🗑️"},
    "list_files" => {"LIST FILES", :cyan, "📁"},
    "grep" => {"GREP", :magenta, "🔍"},
    "run_shell_command" => {"SHELL", :blue, "💻"},
    "create_file" => {"CREATE FILE", :green, "📝"},
    "agent_run" => {"AGENT", :blue, "🤖"},
    "mcp_tool_call" => {"MCP TOOL", :magenta, "🔧"}
  }

  # ── Behaviour Conforming Wrappers ────────────────────────────────────────

  # These implement TUI.Output callbacks so OwlOutput can be used as
  # a swappable output_mod per ADR-007 (code_puppy-057.3).

  @impl true
  def puts(data), do: owl_puts(data)

  @impl true
  def banner(label, color, icon), do: print_banner(label, color, icon)

  @impl true
  def tool_banner(tool_name), do: print_tool_banner(tool_name)

  @impl true
  def start_spinner(loading_index, idx), do: start_tool_spinner(loading_index, idx)

  @impl true
  def stop_tool_spinner(spinner_ids, idx), do: stop_tool_spinner_by_idx(spinner_ids, idx)

  @impl true
  def color_background(color), do: color_background_atom(color)

  # ── Safe Owl Output ──────────────────────────────────────────────────────

  @doc """
  Write data to the terminal via Owl.IO.puts, catching
  :terminated errors that occur when the IO device is closed
  (e.g., ExUnit.CaptureIO released the group leader).

  A terminal write failure must never crash the Renderer GenServer.
  """
  @spec owl_puts(term()) :: :ok
  def owl_puts(data) do
    try do
      Owl.IO.puts(data)
    catch
      :error, :terminated ->
        :ok

      :exit, :terminated ->
        :ok

      kind, reason ->
        Logger.error("TUI.Renderer.OwlOutput: Owl.IO.puts failed: #{kind} #{inspect(reason)}")
        :ok
    end
  end

  # ── Banner Rendering ─────────────────────────────────────────────────────

  @spec print_banner(String.t(), atom(), String.t()) :: :ok
  def print_banner(label, color, icon) do
    tag = Owl.Data.tag(" #{label} ", [:white, color_background_atom(color)])
    icon_str = if icon && icon != "", do: " #{icon}", else: ""
    owl_puts(["\n", tag, icon_str])
    :ok
  end

  @spec print_tool_banner(String.t()) :: :ok
  def print_tool_banner(tool_name) do
    {label, color, icon} = Map.get(@tool_banner_styles, tool_name, {tool_name, :blue, "🔧"})
    print_banner(label, color, icon)
  end

  @spec color_background_atom(atom()) :: atom()
  def color_background_atom(:cyan), do: :cyan_background
  def color_background_atom(:green), do: :green_background
  def color_background_atom(:yellow), do: :yellow_background
  def color_background_atom(:red), do: :red_background
  def color_background_atom(:blue), do: :blue_background
  def color_background_atom(:magenta), do: :magenta_background
  def color_background_atom(_), do: :blue_background

  # ── Spinner Management ──────────────────────────────────────────────────

  @doc """
  Start an Owl.Spinner for a tool call. Returns `{ref, new_loading_index}`
  on success, or `nil` on failure.

  The caller is responsible for storing the ref in `spinner_ids`.
  """
  @spec start_tool_spinner(non_neg_integer(), non_neg_integer()) ::
          {reference(), non_neg_integer()} | nil
  def start_tool_spinner(loading_index, _idx) do
    msg_idx = rem(loading_index, length(@loading_messages))
    label = Enum.at(@loading_messages, msg_idx)

    ref = make_ref()

    spinner_opts = [
      id: ref,
      refresh_every: @spinner_refresh_ms,
      labels: [processing: Owl.Data.tag(label, :faint)]
    ]

    case Owl.Spinner.start(spinner_opts) do
      {:ok, _pid} ->
        {ref, loading_index + 1}

      {:error, reason} ->
        Logger.debug("TUI.Renderer: spinner start failed: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Stop a specific spinner by ref. Catches exit errors from Owl.Spinner.
  """
  @impl true
  @spec stop_spinner(reference()) :: :ok
  def stop_spinner(ref) do
    try do
      Owl.Spinner.stop(id: ref, resolution: :ok)
    catch
      :exit, reason ->
        Logger.debug("TUI.Renderer: spinner stop failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Stop the spinner for a given part index. Returns updated spinner_ids.
  """
  @spec stop_tool_spinner_by_idx(%{non_neg_integer() => reference()}, non_neg_integer()) ::
          %{non_neg_integer() => reference()}
  def stop_tool_spinner_by_idx(spinner_ids, idx) do
    case Map.get(spinner_ids, idx) do
      nil ->
        Logger.debug("TUI.Renderer: no spinner to stop for index #{idx}")
        spinner_ids

      ref ->
        stop_spinner(ref)
        Map.delete(spinner_ids, idx)
    end
  end

  @doc """
  Stop all active spinners. Returns empty spinner_ids map.
  """
  @impl true
  @spec stop_all_spinners(%{non_neg_integer() => reference()}) ::
          %{non_neg_integer() => reference()}
  def stop_all_spinners(spinner_ids) do
    Enum.each(spinner_ids, fn {_idx, ref} -> stop_spinner(ref) end)
    %{}
  end
end
