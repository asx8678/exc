defmodule CodePuppyControl.TUI.Progress do
  @moduledoc """
  Progress indicators backed by Owl.Spinner and Owl.ProgressBar.

  Provides a thin, puppy-friendly wrapper around Owl's live-updating
  terminal widgets. Use this module (not Owl directly) so the rest of
  the codebase stays decoupled from the rendering backend.

  ## Usage

      # Spinner
      {:ok, ref} = Progress.spinner("Compiling...")
      :timer.sleep(2000)
      Progress.stop(ref)

      # Progress bar
      Progress.bar(50, 100, label: "Downloading")
      Progress.bar(100, 100, label: "Downloading")

  ## Design notes

  * `spinner/1` returns `{:ok, ref}` where `ref` is an opaque reference
    generated via `make_ref/0`. This ref is used as the Owl.Spinner `:id`
    for subsequent `stop/2` calls. Callers should **not** store the ref
    across async boundaries without monitoring. For GenServer-managed
    spinners (e.g. the Renderer's tool-call spinners), use the internal
    `Owl.Spinner` API directly with reference tracking.
  * `bar/3` is fire-and-forget — it renders inline and returns `:ok`.
  * All functions are safe to call when Owl is unavailable (e.g. in CI
    with no TTY); they return `{:error, :no_tty}` in that case.
  """

  alias Owl.Data

  # ── Constants ─────────────────────────────────────────────────────────────

  # Progress bar width in terminal columns
  @default_bar_width 40

  # ── Spinner ────────────────────────────────────────────────────────────────

  @doc """
  Starts a labelled spinner in the terminal.

  Returns `{:ok, ref}` on success (where `ref` is an opaque reference for
  use with `stop/2`), `{:error, reason}` on failure.
  When no TTY is available, returns `{:error, :no_tty}`.

  ## Options

    * `:refresh_every` — frame interval in ms (default 80)

  ## Examples

      {:ok, ref} = Progress.spinner("Fetching results...")
      Progress.stop(ref)
  """
  @spec spinner(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def spinner(label, opts \\ []) do
    if tty_available?() do
      refresh = Keyword.get(opts, :refresh_every, 80)
      ref = make_ref()

      spinner_opts = [
        id: ref,
        labels: [processing: Data.tag(label, :faint)],
        refresh_every: refresh
      ]

      case Owl.Spinner.start(spinner_opts) do
        {:ok, _pid} ->
          Owl.Spinner.update_label(id: ref, label: Data.tag(label, :faint))
          {:ok, ref}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_tty}
    end
  end

  @doc """
  Stops a running spinner.

  Accepts the ref returned by `spinner/1`. The spinner is removed from
  the terminal and the line is cleared.

  ## Options

    * `:resolution` — `:ok` (default) or `:error`, controls the final
      icon displayed before removal.

  ## Examples

      Progress.stop(ref)
      Progress.stop(ref, resolution: :error)
  """
  @spec stop(term(), keyword()) :: :ok
  def stop(ref, opts \\ []) do
    resolution = Keyword.get(opts, :resolution, :ok)

    try do
      Owl.Spinner.stop(id: ref, resolution: resolution)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # ── Progress Bar ────────────────────────────────────────────────────────────

  @doc """
  Renders an inline progress bar to the terminal.

  This is a **one-shot** render — it does not start a live-updating
  widget. For live progress, use `Owl.ProgressBar` directly or
  integrate with `Owl.LiveScreen`.

  ## Parameters

    * `current` — items completed so far
    * `total` — total items
    * `opts` — keyword options below

  ## Options

    * `:label` — text shown before the bar (default `""`)
    * `:width` — bar width in columns (default 40)
    * `:color` — ANSI colour atom for the filled portion (default `:cyan`)

  ## Examples

      Progress.bar(25, 100, label: "Files")
      Progress.bar(100, 100, label: "Done")
  """
  @spec bar(non_neg_integer(), non_neg_integer(), keyword()) :: :ok | {:error, :no_tty}
  def bar(current, total, opts \\ []) do
    if tty_available?() do
      label = Keyword.get(opts, :label, "")
      width = Keyword.get(opts, :width, @default_bar_width)
      color = Keyword.get(opts, :color, :cyan)

      %{ratio: _ratio, filled: filled, empty: empty, percentage: pct} =
        compute_bar_segments(current, total, width)

      bar_inner =
        [Data.tag(String.duplicate("\u2588", filled), color), String.duplicate("\u2591", empty)]

      pct_str = "#{pct}%"
      count_str = "(#{current}/#{total})"

      # Build Owl.Data IO list — bar_inner contains Owl.Data.tag/2 tuples
      # which cannot be string-interpolated (lists don't implement String.Chars).
      line =
        if label != "" do
          [label, " [", bar_inner, "] ", pct_str, " ", count_str]
        else
          ["[", bar_inner, "] ", pct_str, " ", count_str]
        end

      Owl.IO.puts(line)
      :ok
    else
      {:error, :no_tty}
    end
  end

  @doc false
  @spec compute_bar_segments(integer(), integer(), non_neg_integer()) :: %{
          ratio: float(),
          filled: non_neg_integer(),
          empty: non_neg_integer(),
          percentage: float()
        }
  def compute_bar_segments(current, total, width) do
    raw_ratio = if total > 0, do: current / total, else: 1.0
    ratio = raw_ratio |> max(0.0) |> min(1.0)
    filled = trunc(ratio * width)
    empty = width - filled
    percentage = Float.round(ratio * 100.0, 1)

    %{ratio: ratio, filled: filled, empty: empty, percentage: percentage}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Detect whether we have a real TTY. Owl gracefully handles no-TTY
  # scenarios, but we short-circuit to avoid visual glitches in CI.
  defp tty_available? do
    case :os.type() do
      {:win32, _} -> true
      _ -> System.get_env("TERM") != nil or System.get_env("COLORTERM") != nil
    end
  end
end
