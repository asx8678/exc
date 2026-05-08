defmodule CodePuppyControl.TUI.Output do
  @moduledoc """
  Output adapter for the TUI renderer.

  Wraps Owl terminal output calls behind a behaviour so the Renderer
  doesn't depend directly on Owl. This makes it possible to:

    - Swap Owl for another terminal library
    - Test output without real terminal devices
    - Capture output for logging/replay

  The default implementation delegates to `CodePuppyControl.TUI.Renderer.OwlOutput`.
  A test implementation can use a simple `IO.puts` or List-based accumulator.
  """

  alias CodePuppyControl.TUI.Renderer.OwlOutput

  @doc "Write data to the terminal."
  @callback puts(data :: term()) :: :ok

  @doc "Render a styled banner with label, color, and icon."
  @callback banner(label :: String.t(), color :: atom(), icon :: String.t()) :: :ok

  @doc "Render a tool-invocation banner by tool name."
  @callback tool_banner(tool_name :: String.t()) :: :ok

  @doc "Start a loading spinner. Returns `{ref, next_loading_index}` or `nil`."
  @callback start_spinner(loading_index :: non_neg_integer(), idx :: non_neg_integer()) ::
              {reference(), non_neg_integer()} | nil

  @doc "Stop a specific spinner by reference."
  @callback stop_spinner(ref :: reference()) :: :ok

  @doc "Stop the spinner for a given part index. Returns updated spinner_ids map."
  @callback stop_tool_spinner(
              spinner_ids :: %{non_neg_integer() => reference()},
              idx :: non_neg_integer()
            ) :: %{non_neg_integer() => reference()}

  @doc "Stop all active spinners. Returns empty spinner_ids map."
  @callback stop_all_spinners(spinner_ids :: %{non_neg_integer() => reference()}) ::
              %{non_neg_integer() => reference()}

  @doc "Map a foreground color atom to its background variant (e.g. `:blue` -> `:blue_background`)."
  @callback color_background(color :: atom()) :: atom()

  @doc """
  Returns the default Owl-based implementation module.
  """
  def default_impl, do: OwlOutput

  # ── Default Delegate Functions ────────────────────────────────────────────
  #
  # These bridge calls from the Renderer (which uses `Output.` as an adapter)
  # to the current OwlOutput implementation. They exist so that renderer.ex
  # doesn't need to be rewritten yet — a future step can configure which
  # implementation module to use via @behaviour + @output_adapter.

  @doc false
  def puts(data), do: OwlOutput.owl_puts(data)

  @doc false
  def print_banner(label, color, icon), do: OwlOutput.print_banner(label, color, icon)

  @doc false
  def print_tool_banner(tool_name), do: OwlOutput.print_tool_banner(tool_name)

  @doc false
  def start_spinner(loading_index, part_index),
    do: OwlOutput.start_tool_spinner(loading_index, part_index)

  @doc false
  def stop_spinner(ref), do: OwlOutput.stop_spinner(ref)

  @doc false
  def stop_all_spinners(spinner_ids), do: OwlOutput.stop_all_spinners(spinner_ids)
end
