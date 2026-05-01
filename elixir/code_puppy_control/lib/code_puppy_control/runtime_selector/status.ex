defmodule CodePuppyControl.RuntimeSelector.Status do
  @moduledoc """
  Runtime selector status reporting for diagnostics and the doctor system.

  Produces structured and human-readable reports of the RuntimeSelector state:
  current mode, per-capability routing decisions, and feature-flag status.
  Used by `Config.Doctor` and the `/feature-flags` slash command.
  """

  alias CodePuppyControl.RuntimeSelector
  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  @type check :: %{
          name: String.t(),
          status: :pass | :warn | :fail | :info,
          detail: String.t()
        }

  @type report :: %{
          mode: :python | :elixir | :auto,
          pup_runtime_env: String.t() | nil,
          capabilities: %{atom() => :python | :elixir},
          feature_flags: %{atom() => boolean()} | %{error: String.t()}
        }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns a diagnostic map of runtime selector state.

  Includes:
    - `:mode` — current routing mode (`:python`, `:elixir`, or `:auto`)
    - `:pup_runtime_env` — value of `PUP_RUNTIME` env var (or `nil`)
    - `:capabilities` — map of capability → selected runtime
    - `:feature_flags` — map of capability → enabled? boolean

  Falls back gracefully if FeatureFlags is unavailable.
  """
  @spec report() :: report()
  def report do
    %{
      mode: RuntimeSelector.current_mode(),
      pup_runtime_env: System.get_env("PUP_RUNTIME"),
      capabilities: capability_report(),
      feature_flags: flag_report()
    }
  end

  @doc """
  Returns doctor-style checks for runtime selector status.

  Each check follows the `%{name, status, detail}` convention used by
  `CodePuppyControl.Config.Doctor`.
  """
  @spec run_checks() :: [check()]
  def run_checks do
    [
      check_runtime_selector_alive(),
      check_mode_consistency(),
      check_capabilities_routable(),
      check_feature_flags_available()
    ]
  end

  @doc """
  Formats a status report as a human-readable string for CLI output.
  """
  @spec format_report() :: String.t()
  def format_report do
    r = report()

    mode_line = "Mode: #{format_mode(r.mode)}"
    env_line = "PUP_RUNTIME: #{r.pup_runtime_env || "(unset — defaults to auto)"}"

    cap_lines =
      r.capabilities
      |> Enum.sort_by(fn {cap, _runtime} -> cap end)
      |> Enum.map(fn {cap, runtime} ->
        flag = Map.get(r.feature_flags, cap)

        flag_detail =
          case r.mode do
            :auto ->
              flag_str = if flag, do: "enabled", else: "disabled"
              " (flag: #{flag_str})"

            _ ->
              ""
          end

        "  #{pad(cap)} → #{runtime}#{flag_detail}"
      end)
      |> Enum.join("\n")

    [
      "⚡ Runtime Selector Status",
      "",
      mode_line,
      env_line,
      "",
      "Capabilities:",
      cap_lines
    ]
    |> Enum.join("\n")
  end

  # ── Doctor Checks ──────────────────────────────────────────────────────

  defp check_runtime_selector_alive do
    case Process.whereis(RuntimeSelector) do
      nil ->
        %{
          name: "RuntimeSelector GenServer is running",
          status: :fail,
          detail: "GenServer not running — all routing falls back to :python"
        }

      _pid ->
        %{
          name: "RuntimeSelector GenServer is running",
          status: :pass,
          detail: ""
        }
    end
  end

  defp check_mode_consistency do
    mode = RuntimeSelector.current_mode()
    env = System.get_env("PUP_RUNTIME")
    env_mode = parse_env_as_mode(env)

    cond do
      env == nil and mode == :auto ->
        %{name: "RuntimeSelector mode matches PUP_RUNTIME", status: :pass, detail: ""}

      env_mode == mode ->
        %{name: "RuntimeSelector mode matches PUP_RUNTIME", status: :pass, detail: ""}

      env != nil and env_mode == :auto and mode == :auto ->
        %{
          name: "RuntimeSelector mode matches PUP_RUNTIME",
          status: :warn,
          detail: "PUP_RUNTIME=#{env} parsed as :auto (unknown value), mode is :auto"
        }

      true ->
        %{
          name: "RuntimeSelector mode matches PUP_RUNTIME",
          status: :warn,
          detail:
            "PUP_RUNTIME=#{inspect(env)} but mode is #{mode} (may have been set dynamically)"
        }
    end
  end

  defp check_capabilities_routable do
    r = report()
    all_python = Enum.all?(r.capabilities, fn {_, rt} -> rt == :python end)
    all_elixir = Enum.all?(r.capabilities, fn {_, rt} -> rt == :elixir end)

    cond do
      all_python and r.mode == :elixir ->
        %{
          name: "Capability routing is consistent",
          status: :warn,
          detail: "mode is :elixir but some capabilities route to :python (check feature flags)"
        }

      all_elixir and r.mode == :python ->
        %{
          name: "Capability routing is consistent",
          status: :warn,
          detail: "mode is :python but some capabilities route to :elixir (unexpected)"
        }

      true ->
        %{name: "Capability routing is consistent", status: :pass, detail: ""}
    end
  end

  defp check_feature_flags_available do
    case Process.whereis(FeatureFlags) do
      nil ->
        %{
          name: "FeatureFlags GenServer is running",
          status: :warn,
          detail: "not running — all flags default to false in :auto mode"
        }

      _pid ->
        %{name: "FeatureFlags GenServer is running", status: :pass, detail: ""}
    end
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp capability_report do
    Map.new(Flags.names(), fn cap ->
      {cap, RuntimeSelector.select_runtime(cap)}
    end)
  end

  defp flag_report do
    Map.new(Flags.names(), fn cap ->
      {cap, FeatureFlags.enabled?(cap)}
    end)
  rescue
    _ -> %{error: "FeatureFlags unavailable"}
  catch
    :exit, _ -> %{error: "FeatureFlags unavailable"}
  end

  defp format_mode(:python), do: "python (all → Python)"
  defp format_mode(:elixir), do: "elixir (all → Elixir)"
  defp format_mode(:auto), do: "auto (per-capability via feature flags)"

  defp pad(atom) when is_atom(atom) do
    String.pad_trailing(Atom.to_string(atom), 14)
  end

  defp parse_env_as_mode(nil), do: :auto

  defp parse_env_as_mode(raw) when is_binary(raw) do
    case String.downcase(raw) do
      "python" -> :python
      "elixir" -> :elixir
      "auto" -> :auto
      _unknown -> :auto
    end
  end
end
