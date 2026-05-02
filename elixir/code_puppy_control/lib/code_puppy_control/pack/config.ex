defmodule CodePuppyControl.Pack.Config do
  @moduledoc """
  Configuration reader for distributed pack settings.

  Reads `[packs.distributed]` section from `puppy.cfg`.

  (Phase I.1 — code_puppy-yge.2)
  """

  @defaults %{
    enabled: false,
    node_name: nil,
    cookie: nil,
    workers: [],
    connect_timeout: 5_000,
    heartbeat_interval: 15_000,
    disconnect_timeout: 30_000,
    dispatch_style: :async,
    sync_timeout: 30_000
  }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Loads and returns the distributed pack configuration merged with defaults.

  Reads from `Application.get_env(:code_puppy_control, :distributed_packs, %{})`
  first, then merges with built-in defaults. Any keys present in the app env
  override the defaults.

  ## Examples

      CodePuppyControl.Pack.Config.load()
      #=> %{enabled: false, workers: [], heartbeat_interval: 15_000, ...}
  """
  @spec load() :: map()
  def load do
    app_env = Application.get_env(:code_puppy_control, :distributed_packs, %{})

    # Normalize to map if keyword list was provided
    app_map = if is_list(app_env), do: Map.new(app_env), else: app_env

    Map.merge(@defaults, app_map)
  end

  @doc """
  Returns whether distributed packs are enabled.

  Shortcut for `load().enabled`. Defaults to `false`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: load().enabled == true

  @doc """
  Returns the list of configured worker node atoms.

  Shortcut for `load().workers`. Defaults to `[]`.
  """
  @spec workers() :: [node()]
  def workers, do: load().workers || []

  @doc """
  Returns the configured Erlang distribution cookie, or nil.

  Shortcut for `load().cookie`. Defaults to `nil`.
  """
  @spec cookie() :: atom() | nil
  def cookie, do: load().cookie

  @doc """
  Returns the default values map used as fallback.
  Useful for testing and documentation.
  """
  @spec defaults() :: map()
  def defaults, do: @defaults
end
