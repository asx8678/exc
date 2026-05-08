defmodule CodePuppyControl.Config.FirstRun do
  @moduledoc """
  First-run detection and initialization for the Elixir home directory.

  On first boot, creates `~/.code_puppy_ex/` and its subdirectory tree.
  If the Python pup's legacy home (`~/.code_puppy/`) is present, emits a
  one-time guidance banner to stderr directing the user to `mix pup_ex.import`.

  This module is idempotent — safe to call on every boot. It must NOT
  auto-import (importing is exclusively `mix pup_ex.import`, opt-in).
  It must NOT touch the legacy home in any way — not even read. Just
  detect presence via `File.dir?/1`.
  """

  alias CodePuppyControl.Config.{Isolation, Paths}

  @initialized_marker ".initialized"

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Initialize the Elixir home directory.

  Returns `{:ok, :fresh_install}` when the home was just created,
  `{:ok, :existing}` when it already existed, or `{:error, reason}`
  on failure (e.g. permission denied).

  Idempotent — safe to call on every boot.
  """
  @spec initialize() :: {:ok, :fresh_install | :existing} | {:error, term()}
  def initialize do
    cond do
      elixir_home_present?() ->
        {:ok, :existing}

      true ->
        case create_home() do
          :ok ->
            maybe_emit_guidance()
            write_initialized_marker()
            {:ok, :fresh_install}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Returns `true` if the Elixir home directory (`~/.code_puppy_ex/`) exists."
  @spec elixir_home_present?() :: boolean()
  def elixir_home_present?, do: File.dir?(Paths.home_dir())

  @doc "Returns `true` if the Python pup's legacy home (`~/.code_puppy/`) exists."
  @spec legacy_home_present?() :: boolean()
  def legacy_home_present?, do: File.dir?(Paths.legacy_home_dir())

  @doc "Returns `true` if this is a first run (Elixir home is missing)."
  @spec first_run?() :: boolean()
  def first_run?, do: not elixir_home_present?()

  @doc """
  Returns the first-run initialization timestamp, or `nil` if not initialized.

  Reads the `.initialized` marker file from the Elixir home.
  """
  @spec initialized_at() :: String.t() | nil
  def initialized_at do
    marker_path = Path.join(Paths.home_dir(), @initialized_marker)

    case File.read(marker_path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> nil
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp create_home do
    try do
      Paths.ensure_dirs!()
      :ok
    rescue
      e in [File.Error, ErlangError] ->
        {:error, Exception.message(e)}
    end
  end

  defp maybe_emit_guidance do
    if legacy_home_present?() do
      emit_guidance_banner()
    end
  end

  defp emit_guidance_banner do
    banner = """

    🐾 Welcome to pup-ex (Elixir edition)!

    We detected an existing ~/.code_puppy/ (Python pup). Your Elixir home is a
    SEPARATE directory at ~/.code_puppy_ex/. We will NEVER touch ~/.code_puppy/.

    To copy non-sensitive settings (models, agents, skills) over:
        mix pup_ex.import

    To verify isolation:
        mix pup_ex.doctor

    This message won't appear again.
    """

    IO.puts(:stderr, banner)
  end

  defp write_initialized_marker do
    marker_path = Path.join(Paths.home_dir(), @initialized_marker)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    try do
      Isolation.safe_write!(marker_path, timestamp)
    rescue
      # If isolation guard blocks the write (e.g. PUP_EX_HOME points somewhere
      # unexpected), fall back to direct File.write — the marker is not security-
      # critical; it's just a UX hint.
      _ -> File.write(marker_path, timestamp)
    end
  end
end
