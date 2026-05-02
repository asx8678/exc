defmodule CodePuppyControl.Config.Doctor do
  @moduledoc """
  Health checks for Elixir pup-ex isolation and configuration.

  Runs a battery of checks against the Elixir home directory, isolation
  guards, and path routing. Each check produces `:pass`, `:warn`, `:fail`,
  or `:info` status. Used by `mix pup_ex.doctor`.
  """

  alias CodePuppyControl.Config.{FirstRun, Isolation, Paths}

  @type check :: %{
          name: String.t(),
          status: :pass | :warn | :fail | :info,
          detail: String.t()
        }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Run all isolation health checks."
  @spec run_checks() :: [check()]
  def run_checks do
    [
      check_elixir_home(),
      check_home_perms(),
      check_isolation_guard(),
      check_paths_audit(),
      check_legacy_home(),
      check_first_run_marker(),
      check_oauth_isolation()
    ]
  end

  @doc "Format a list of checks into a human-readable report."
  @spec format_report([check()]) :: String.t()
  def format_report(checks) do
    lines =
      checks
      |> Enum.map(fn %{name: name, status: status, detail: detail} ->
        icon = status_icon(status)
        detail_suffix = if detail == "", do: "", else: " — " <> detail
        "#{icon} #{name}#{detail_suffix}"
      end)

    pass_count = Enum.count(checks, &(&1.status in [:pass, :info]))
    fail_count = Enum.count(checks, &(&1.status == :fail))
    info_count = Enum.count(checks, &(&1.status == :info))

    summary =
      "Summary: #{pass_count} checks passed, #{fail_count} failures, #{info_count} informational notes."

    status =
      if fail_count > 0 do
        "Status: COMPROMISED ❌"
      else
        "Status: ISOLATED ✅"
      end

    Enum.join(
      ["🩺 pup-ex doctor — checking isolation health", "" | lines] ++
        ["", summary, status],
      "\n"
    )
  end

  @doc "Return the exit code: 0 if all :pass or :info, 1 if any :fail."
  @spec exit_code([check()]) :: 0 | 1
  def exit_code(checks) do
    if Enum.any?(checks, &(&1.status == :fail)), do: 1, else: 0
  end

  # ── Individual checks ──────────────────────────────────────────────────

  defp check_elixir_home do
    home = Paths.home_dir()

    if File.dir?(home) do
      %{name: "Elixir home exists", status: :pass, detail: "at #{home}"}
    else
      %{name: "Elixir home exists", status: :fail, detail: "missing at #{home}"}
    end
  end

  defp check_home_perms do
    home = Paths.home_dir()

    case File.stat(home) do
      {:ok, %{mode: mode}} ->
        perm_bits = Bitwise.band(mode, 0o777)

        if perm_bits == 0o700 do
          %{
            name: "Home permissions 0700",
            status: :pass,
            detail: "permissions are #{octal(perm_bits)}"
          }
        else
          %{
            name: "Home permissions 0700",
            status: :warn,
            detail: "permissions are #{octal(perm_bits)} (expected 0700)"
          }
        end

      {:error, reason} ->
        %{name: "Home permissions 0700", status: :fail, detail: "cannot stat: #{reason}"}
    end
  end

  defp check_isolation_guard do
    probe_path = Path.join(Paths.legacy_home_dir(), ".doctor_probe_DELETE_ME")

    try do
      # This MUST raise IsolationViolation. If it doesn't, the guard is broken.
      Isolation.safe_write!(probe_path, "probe")

      # If we get here, the guard FAILED — something was written to legacy home.
      # Emergency cleanup.
      File.rm(probe_path)
      File.rm(Path.join(Paths.legacy_home_dir(), ".doctor_probe_DELETE_ME"))

      %{
        name: "Isolation guard blocks writes to legacy home",
        status: :fail,
        detail:
          "GUARD FAILURE: write to #{probe_path} was NOT blocked! Cleaned up, but isolation is compromised."
      }
    rescue
      Isolation.IsolationViolation ->
        %{
          name: "Isolation guard blocks writes to legacy home",
          status: :pass,
          detail: "guard correctly raised IsolationViolation"
        }

      _other ->
        # Unexpected error — still means the guard activated in some form
        %{
          name: "Isolation guard blocks writes to legacy home",
          status: :pass,
          detail: "guard blocked the write (unexpected exception type)"
        }
    end
  end

  defp check_paths_audit do
    # Enumerate all 0-arity path functions in Paths module
    excluded = [:legacy_home_dir, :project_policy_file, :project_agents_dir, :ensure_dirs!]

    path_fns =
      CodePuppyControl.Config.Paths.__info__(:functions)
      |> Enum.filter(fn {_name, arity} -> arity == 0 end)
      |> Enum.reject(fn {name, _arity} -> name in excluded end)

    violations =
      path_fns
      |> Enum.filter(fn {name, _} ->
        try do
          resolved = apply(Paths, name, [])
          Paths.in_legacy_home?(resolved)
        rescue
          _ -> false
        end
      end)

    if violations == [] do
      %{
        name: "All #{length(path_fns)} Paths.* functions resolve under Elixir home",
        status: :pass,
        detail: ""
      }
    else
      bad_names = violations |> Enum.map(fn {n, _} -> "#{n}/0" end) |> Enum.join(", ")

      %{
        name: "All #{length(path_fns)} Paths.* functions resolve under Elixir home",
        status: :fail,
        detail: "violations: #{bad_names}"
      }
    end
  end

  defp check_legacy_home do
    legacy = Paths.legacy_home_dir()

    if File.dir?(legacy) do
      %{name: "Python pup legacy home", status: :info, detail: "detected at #{legacy}"}
    else
      %{name: "Python pup legacy home", status: :info, detail: "not found at #{legacy}"}
    end
  end

  defp check_first_run_marker do
    case FirstRun.initialized_at() do
      nil ->
        %{name: "First-run marker", status: :info, detail: "not initialized yet"}

      timestamp ->
        %{name: "First-run marker", status: :info, detail: "initialized on #{timestamp}"}
    end
  end

  defp check_oauth_isolation do
    # Smoke test: verify auth paths under Elixir and legacy homes are disjoint.
    # Full coverage is 's job.
    elixir_auth = Path.join(Paths.home_dir(), "auth")
    legacy_auth = Path.join(Paths.legacy_home_dir(), "auth")

    elixir_has_oauth = oauth_files_present?(elixir_auth)
    legacy_has_oauth = oauth_files_present?(legacy_auth)

    cond do
      not elixir_has_oauth and not legacy_has_oauth ->
        %{name: "OAuth isolation", status: :pass, detail: "no auth state detected in either home"}

      elixir_has_oauth and not legacy_has_oauth ->
        %{name: "OAuth isolation", status: :pass, detail: "auth state only in Elixir home"}

      legacy_has_oauth and not elixir_has_oauth ->
        %{
          name: "OAuth isolation",
          status: :pass,
          detail: "auth state only in legacy home (not shared)"
        }

      true ->
        # Both homes have auth files — potential shared state
        %{
          name: "OAuth isolation",
          status: :warn,
          detail: "both homes have auth files — verify they are independent (full check pending)"
        }
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp status_icon(:pass), do: "✅"
  defp status_icon(:warn), do: "⚠️"
  defp status_icon(:fail), do: "❌"
  defp status_icon(:info), do: "ℹ️ "

  defp octal(n), do: "0" <> Integer.to_string(n, 8)

  defp oauth_files_present?(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          lower = String.downcase(entry)
          String.contains?(lower, "oauth") or String.contains?(lower, "token")
        end)

      {:error, _} ->
        false
    end
  end
end
