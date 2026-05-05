defmodule CodePuppyControl.CLI.Smoke.Phases do
  @moduledoc """
  Phase implementations for `CodePuppyControl.CLI.Smoke`.

  Split out of `Smoke` to keep individual modules under the 600-line
  cap.  The phases here are dispatched by `Smoke.run_phases/2` and are
  not meant to be called directly by application code — call
  `Smoke.run/1` (or `Smoke.run_phases/2` from a Mix task).

  Refs: code_puppy-baa
  """

  alias CodePuppyControl.CLI
  alias CodePuppyControl.CLI.Parser
  alias CodePuppyControl.CLI.Smoke
  alias CodePuppyControl.CLI.Smoke.BurritoArtifact
  alias CodePuppyControl.CLI.Smoke.MockLLM
  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.REPL.OneShot
  alias CodePuppyControl.Tools.AgentCatalogue

  @type phase_result :: %{
          phase: atom(),
          status: :pass | :fail | :skip,
          detail: String.t(),
          metrics: map()
        }

  # ── Phase: parser ─────────────────────────────────────────────────────

  @doc false
  @spec parser() :: phase_result()
  def parser do
    cases = [
      {["--help"], :help_tag, fn -> match?({:help, _}, Parser.parse(["--help"])) end},
      {["--version"], :version_tag, fn -> match?({:version, _}, Parser.parse(["--version"])) end},
      {["-p", "hello"], :ok_tag,
       fn ->
         match?({:ok, %{prompt: "hello"}}, Parser.parse(["-p", "hello"]))
       end},
      {["--bogus"], :error_tag,
       fn ->
         match?({:error, _msg}, Parser.parse(["--bogus"]))
       end},
      {[:help_text, :body], :help_text_invariants,
       fn ->
         text = CLI.help_text()

         text =~ "Usage: pup [OPTIONS] [PROMPT]" and
           text =~ "code-puppy " and
           text =~ "--prompt"
       end}
    ]

    failures =
      Enum.reduce(cases, [], fn {label, tag, predicate}, acc ->
        if safe_predicate(predicate) do
          acc
        else
          [{label, tag} | acc]
        end
      end)

    if failures == [] do
      %{
        phase: :parser,
        status: :pass,
        detail: "argv parsing + help text invariants ok",
        metrics: %{cases: length(cases)}
      }
    else
      %{
        phase: :parser,
        status: :fail,
        detail: "parser case(s) failed: #{inspect(Enum.reverse(failures))}",
        metrics: %{cases: length(cases), failed: length(failures)}
      }
    end
  end

  # ── Phase: run_mode ────────────────────────────────────────────────────

  @doc false
  @spec run_mode() :: phase_result()
  def run_mode do
    expectations = [
      {%{prompt: "hello"}, :one_shot},
      {%{prompt: "hello", interactive: true}, :interactive_with_prompt},
      {%{continue: true}, :continue_session},
      {%{}, :interactive_default},
      {%{prompt: nil}, :interactive_default},
      {%{prompt: ""}, :interactive_default},
      {%{prompt: "hi", continue: true}, :continue_session}
    ]

    failures =
      Enum.reduce(expectations, [], fn {input, expected}, acc ->
        actual =
          try do
            CLI.resolve_run_mode(input)
          rescue
            err -> {:raised, err}
          end

        if actual == expected, do: acc, else: [{input, expected, actual} | acc]
      end)

    if failures == [] do
      %{
        phase: :run_mode,
        status: :pass,
        detail: "run-mode resolver routes all known inputs",
        metrics: %{cases: length(expectations)}
      }
    else
      %{
        phase: :run_mode,
        status: :fail,
        detail: "run-mode mismatches: #{inspect(Enum.reverse(failures))}",
        metrics: %{cases: length(expectations), failed: length(failures)}
      }
    end
  end

  # ── Phase: sandbox ────────────────────────────────────────────────────

  @doc false
  @spec sandbox(map()) :: phase_result()
  def sandbox(sandbox) do
    home_resolved = Paths.home_dir()
    legacy = Paths.legacy_home_dir()
    real_default = Path.expand("~/.code_puppy_ex")

    checks = [
      {home_resolved == sandbox.dir, "Paths.home_dir/0 resolves to sandbox"},
      {Paths.in_legacy_home?(legacy) == true, "legacy home detected as legacy"},
      {Paths.in_legacy_home?(sandbox.dir) == false, "sandbox not under legacy home"},
      {home_resolved != real_default,
       "Paths.home_dir/0 must NOT equal real ~/.code_puppy_ex during smoke"},
      {sandbox.dir |> File.dir?(), "sandbox dir exists on disk"}
    ]

    failures = for {ok?, label} <- checks, not ok?, do: label

    if failures == [] do
      %{
        phase: :sandbox,
        status: :pass,
        detail: "sandbox isolated; PUP_EX_HOME=#{home_resolved}",
        metrics: %{checks: length(checks)}
      }
    else
      %{
        phase: :sandbox,
        status: :fail,
        detail: "sandbox checks failed: #{inspect(failures)}",
        metrics: %{checks: length(checks), failed: length(failures)}
      }
    end
  end

  # ── Phase: one_shot ───────────────────────────────────────────────────

  @doc false
  @spec one_shot(map()) :: phase_result()
  def one_shot(_sandbox) do
    if not application_started?() do
      %{
        phase: :one_shot,
        status: :skip,
        detail:
          "code_puppy_control application not started — invoke from `mix pup_ex.smoke`" <>
            " or call Application.ensure_all_started/1 first",
        metrics: %{}
      }
    else
      do_one_shot()
    end
  end

  defp do_one_shot do
    prev_llm = Application.get_env(:code_puppy_control, :repl_llm_module)
    Application.put_env(:code_puppy_control, :repl_llm_module, MockLLM)
    MockLLM.reset()

    safe_discover_agents()

    session_id = "smoke-" <> random_hex(4)
    prompt = "smoke probe — no network"

    {captured, run_outcome} =
      capture_group_leader(fn ->
        OneShot.run(%{prompt: prompt, session_id: session_id})
      end)

    {return_value, raised} =
      case run_outcome do
        {:ok, value} -> {value, nil}
        {:raised, err} -> {:__raised__, err}
        {:caught, kind_reason} -> {:__caught__, kind_reason}
      end

    # Drain async session saves before we tear down env vars.
    Process.sleep(150)

    try do
      build_one_shot_result(raised, return_value, captured, session_id, prompt)
    after
      restore_repl_llm(prev_llm)
    end
  end

  defp build_one_shot_result(raised, return_value, captured, session_id, prompt) do
    cond do
      match?(%{__struct__: _}, raised) ->
        %{
          phase: :one_shot,
          status: :fail,
          detail:
            "OneShot.run/1 raised #{inspect(raised.__struct__)}: " <>
              Exception.message(raised),
          metrics: %{invocation_count: MockLLM.invocation_count()}
        }

      is_tuple(raised) ->
        %{
          phase: :one_shot,
          status: :fail,
          detail: "OneShot.run/1 caught: #{inspect(raised)}",
          metrics: %{invocation_count: MockLLM.invocation_count()}
        }

      return_value != :ok ->
        %{
          phase: :one_shot,
          status: :fail,
          detail: "OneShot.run/1 returned #{inspect(return_value)} (expected :ok)",
          metrics: %{invocation_count: MockLLM.invocation_count()}
        }

      MockLLM.invocation_count() != 1 ->
        %{
          phase: :one_shot,
          status: :fail,
          detail: "MockLLM was invoked #{MockLLM.invocation_count()} times (expected exactly 1)",
          metrics: %{invocation_count: MockLLM.invocation_count()}
        }

      not (captured =~ MockLLM.canned_reply()) ->
        %{
          phase: :one_shot,
          status: :fail,
          detail:
            "captured stdout did not contain mock reply " <>
              "(expected #{inspect(MockLLM.canned_reply())})",
          metrics: %{
            invocation_count: MockLLM.invocation_count(),
            captured_bytes: byte_size(captured)
          }
        }

      true ->
        %{
          phase: :one_shot,
          status: :pass,
          detail: "OneShot.run/1 dispatched to MockLLM and rendered canned reply",
          metrics: %{
            invocation_count: MockLLM.invocation_count(),
            session_id: session_id,
            prompt_bytes: byte_size(prompt),
            captured_bytes: byte_size(captured)
          }
        }
    end
  end

  defp restore_repl_llm(nil) do
    Application.delete_env(:code_puppy_control, :repl_llm_module)
  end

  defp restore_repl_llm(prev) do
    Application.put_env(:code_puppy_control, :repl_llm_module, prev)
  end

  # ── Phase: escript (opt-in) ───────────────────────────────────────────

  @doc false
  @spec escript(keyword()) :: phase_result()
  def escript(opts \\ []) do
    no_python = Keyword.get(opts, :no_python, false)
    sandbox_dir = Keyword.get(opts, :sandbox_dir)

    candidates = [
      Path.join(File.cwd!(), "pup"),
      Path.expand("../../../pup", __DIR__),
      Path.expand("../../../../pup", __DIR__)
    ]

    case Enum.find(candidates, &File.regular?/1) do
      nil ->
        %{
          phase: :escript,
          status: :skip,
          detail:
            "no `pup` escript found — build with `MIX_ENV=prod mix escript.build` " <>
              "to exercise this phase",
          metrics: %{candidates: candidates}
        }

      path ->
        probe_packaged_cli(:escript, path, no_python: no_python, sandbox_dir: sandbox_dir)
    end
  end

  # ── Phase: burrito (opt-in) ───────────────────────────────────────────

  # Burrito drops binaries under `burrito_out/<release_name>_<target>` after
  # `MIX_ENV=prod mix release`.  Building Burrito artifacts requires Zig and
  # is expensive; this phase is opt-in and skips deterministically when no
  # artifact is present, so CI without a Zig toolchain stays green.
  #
  # Refs: code_puppy-d7m
  @doc false
  @spec burrito(keyword()) :: phase_result()
  def burrito(opts \\ []) do
    no_python = Keyword.get(opts, :no_python, false)
    sandbox_dir = Keyword.get(opts, :sandbox_dir)

    case BurritoArtifact.find_burrito_artifact() do
      {:ok, path} ->
        probe_packaged_cli(:burrito, path, no_python: no_python, sandbox_dir: sandbox_dir)

      {:skip, reason, metrics} ->
        %{
          phase: :burrito,
          status: :skip,
          detail: reason,
          metrics: metrics
        }
    end
  end

  # The Burrito artifact-selection helpers live in
  # `CodePuppyControl.CLI.Smoke.BurritoArtifact` so this module stays
  # under the 600-line cap.  We re-export the public-but-undocumented
  # entry points used by the regression test in
  # `test/code_puppy_control/cli/smoke/burrito_artifact_test.exs` so the
  # test surface is unchanged.  Behaviour (including Windows `.exe`
  # handling and the strict host-compat contract) is preserved exactly.
  #
  # Refs: code_puppy-d7m
  @doc false
  defdelegate probe_burrito_dir(burrito_dir, candidate_targets), to: BurritoArtifact

  @doc false
  defdelegate candidate_filenames(target), to: BurritoArtifact

  @doc false
  defdelegate host_compatible_targets(), to: BurritoArtifact

  # ── Shared probe helper ───────────────────────────────────────────────

  # Run the canonical no-network smoke probes against a packaged CLI
  # binary (escript or Burrito).  Probes are deterministic and touch
  # zero network/auth state:
  #
  #   1. `--version`  must exit 0 and contain the marker `code-puppy`.
  #   2. `--help`     must exit 0 and contain the markers
  #                   `Usage: pup [OPTIONS] [PROMPT]` and `--prompt`.
  #   3. Interactive bootstrap/quit — pipes `/quit\n` into the binary
  #      with a sandboxed PUP_EX_HOME and PUP_RUNTIME=elixir, then
  #      asserts the process exits 0 without crash indicators in
  #      its output.  This catches escript startup failures where
  #      erlexec cannot find its exec-port, the supervision tree
  #      is degraded, or core ETS tables/supervisors are missing.
  #
  # Always invokes the binary with the active `PUP_EX_HOME` (so any
  # accidental config touch lands in the smoke sandbox, NEVER
  # `~/.code_puppy_ex/`) and `PUP_SMOKE_PROBE=1` so callees can
  # detect-and-shortcircuit if they ever need to.
  defp probe_packaged_cli(phase, path, opts) do
    no_python = Keyword.get(opts, :no_python, false)
    sandbox_dir = Keyword.get(opts, :sandbox_dir)

    env =
      if no_python do
        Smoke.no_python_packaged_env(sandbox_dir: sandbox_dir)
      else
        packaged_cli_env()
      end

    # (code-puppy-nml) The escript can now start without PUP_SECRET_KEY_BASE
    # and PUP_DATABASE_PATH because runtime.exs detects escript mode and
    # skips validation. Do NOT inject these env vars — the probe must prove
    # that plain `./pup` works without them.
    #
    # For escript, also run an explicit no-env bootstrap that explicitly
    # unsets PUP_SECRET_KEY_BASE/PUP_DATABASE_PATH from the child
    # environment to prove the escript can start without them even when
    # inherited from the parent process.
    no_env_bootstrap_result =
      if phase == :escript do
        no_env = sanitize_prod_secrets(env)
        run_interactive_bootstrap(path, no_env)
      end

    with {:version, {ver_out, 0}} <-
           {:version, System.cmd(path, ["--version"], stderr_to_stdout: true, env: env)},
         true <- ver_out =~ "code-puppy" || {:fail, :version_marker_missing, ver_out},
         {:help, {help_out, 0}} <-
           {:help, System.cmd(path, ["--help"], stderr_to_stdout: true, env: env)},
         true <-
           help_out =~ "Usage: pup [OPTIONS] [PROMPT]" ||
             {:fail, :help_usage_missing, help_out},
         true <- help_out =~ "--prompt" || {:fail, :help_prompt_flag_missing, help_out},
         {:bootstrap, bootstrap_result} <-
           {:bootstrap, run_interactive_bootstrap(path, env)} do
      case bootstrap_result do
        {:ok, bootstrap_out} ->
          bootstrap_errors = detect_bootstrap_errors(bootstrap_out)

          # For escript, also validate the explicit no-env bootstrap
          no_env_errors =
            case no_env_bootstrap_result do
              {:ok, no_env_out} ->
                detect_bootstrap_errors(no_env_out)

              {:error, reason} ->
                ["no-env bootstrap failed: #{String.slice(to_string(reason), 0, 100)}"]

              nil ->
                # Not an escript probe, skip
                []
            end

          all_errors = bootstrap_errors ++ no_env_errors

          if all_errors == [] do
            detail =
              if no_env_bootstrap_result != nil do
                "#{phase} --version, --help, interactive bootstrap/quit, " <>
                  "and no-env bootstrap/quit exited 0 with stable markers"
              else
                "#{phase} --version, --help, and interactive bootstrap/quit " <>
                  "exited 0 with stable markers"
              end

            metrics =
              %{
                path: path,
                version_bytes: byte_size(ver_out),
                help_bytes: byte_size(help_out),
                bootstrap_bytes: byte_size(bootstrap_out)
              }

            metrics =
              case no_env_bootstrap_result do
                {:ok, no_env_out} ->
                  Map.put(metrics, :no_env_bootstrap_bytes, byte_size(no_env_out))

                _ ->
                  metrics
              end

            %{
              phase: phase,
              status: :pass,
              detail: detail,
              metrics: metrics
            }
          else
            %{
              phase: phase,
              status: :fail,
              detail:
                "#{phase} interactive bootstrap/quit detected errors: " <>
                  Enum.join(all_errors, "; "),
              metrics: %{
                path: path,
                bootstrap_bytes: byte_size(bootstrap_out),
                errors: all_errors
              }
            }
          end
      end
    else
      {:version, {output, exit_status}} ->
        %{
          phase: phase,
          status: :fail,
          detail:
            "#{phase} --version exited #{exit_status}: " <>
              inspect(String.slice(output, 0, 120)),
          metrics: %{path: path, exit_status: exit_status, probe: "--version"}
        }

      {:help, {output, exit_status}} ->
        %{
          phase: phase,
          status: :fail,
          detail:
            "#{phase} --help exited #{exit_status}: " <>
              inspect(String.slice(output, 0, 120)),
          metrics: %{path: path, exit_status: exit_status, probe: "--help"}
        }

      {:fail, reason, output} ->
        %{
          phase: phase,
          status: :fail,
          detail:
            "#{phase} probe missing marker (#{reason}); first 120 bytes: " <>
              inspect(String.slice(output, 0, 120)),
          metrics: %{path: path, reason: reason}
        }

      {:bootstrap, {:error, reason}} ->
        %{
          phase: phase,
          status: :fail,
          detail:
            "#{phase} interactive bootstrap/quit failed: #{inspect(String.slice(to_string(reason), 0, 200))}",
          metrics: %{path: path, probe: "interactive_bootstrap"}
        }
    end
  rescue
    err ->
      %{
        phase: phase,
        status: :fail,
        detail: "#{phase} probe raised #{inspect(err.__struct__)}: #{Exception.message(err)}",
        metrics: %{path: path}
      }
  end

  # Pipe `/quit\n` into the packaged CLI with a sandboxed environment
  # and capture all output.  Returns `{:ok, output}` on success (exit 0)
  # or `{:error, reason}` on unexpected failure.  Uses a 15-second
  # timeout to prevent hangs.
  #
  # (code-puppy-fut) Uses System.cmd/3 with a temp stdin file piped
  # via `sh -c`.  Paths are escaped with shell_single_quote_escape/1
  # to prevent breakage on single quotes in filenames (the classic
  # `it's` → `'it'\''s'` idiom).  No misleading Port comments.
  defp run_interactive_bootstrap(path, env) do
    # Write the /quit command to a temp file.
    tmp_dir = System.tmp_dir!()
    uniq = :erlang.unique_integer([:positive])
    stdin_file = Path.join(tmp_dir, "pup_smoke_stdin_#{uniq}")

    try do
      File.write!(stdin_file, "/quit\n")

      task =
        Task.async(fn ->
          try do
            System.cmd("sh", ["-c", "cat '#{shell_sq(stdin_file)}' | '#{shell_sq(path)}'"],
              stderr_to_stdout: true,
              env: env
            )
          catch
            kind, reason -> {kind, reason}
          end
        end)

      case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok, output}

        {:ok, {output, exit_status}} when is_integer(exit_status) ->
          {:error, "exited #{exit_status}: #{String.slice(output, 0, 200)}"}

        {:ok, {:exit, reason}} ->
          {:error, "port exited: #{inspect(reason)}"}

        nil ->
          # Task timed out and was killed
          {:error, "interactive bootstrap timed out after 15s"}
      end
    after
      File.rm(stdin_file)
    end
  end

  # Escape a string for safe interpolation inside POSIX single quotes.
  # In a single-quoted shell context, the only character that needs
  # escaping is the single quote itself.  The standard idiom ends
  # the current quote, adds an escaped single quote, and reopens:
  #
  #     it's  →  'it'\''s'
  #
  # This is safe even for strings containing backslashes, dollar
  # signs, or other shell metacharacters because single-quoting
  # suppresses all interpretation.
  @spec shell_sq(String.t()) :: String.t()
  defp shell_sq(s) do
    String.replace(s, "'", "'\\''")
  end

  # Scan interactive bootstrap output for crash indicators that signal
  # the OTP supervision tree is degraded.  Returns a list of error
  # description strings (empty = clean).
  #
  # (code-puppy-be7) Since bootstrap now must exit 0 (not just have the
  # CLI guard catch a failure), we also flag FATAL messages as errors
  # because they indicate the guard prevented REPL entry.
  defp detect_bootstrap_errors(output) do
    error_patterns = [
      {"FATAL: code_puppy_control application failed to start",
       "application startup failed (FATAL message in output)"},
      {"FATAL: core OTP components are not alive",
       "core OTP components missing (FATAL message in output)"},
      {"No exec-port files found", "erlexec exec-port not found"},
      {"Application erlexec exited", "erlexec application crashed"},
      {"ArgumentError", "ArgumentError during startup"}
    ]

    for {pattern, label} <- error_patterns,
        String.contains?(output, pattern),
        do: label
  end

  defp packaged_cli_env do
    [
      {"PUP_EX_HOME", System.get_env("PUP_EX_HOME") || ""},
      {"PUP_SMOKE_PROBE", "1"}
    ]
  end

  # Explicitly unset PUP_SECRET_KEY_BASE and PUP_DATABASE_PATH (and their
  # legacy names) in the child process environment.  This proves the
  # escript can start without these prod env vars. (code-puppy-nml)
  #
  # System.cmd/3 interprets a `nil` value as "unset in child process".
  @prod_secret_env_vars [
    "PUP_SECRET_KEY_BASE",
    "SECRET_KEY_BASE",
    "PUP_DATABASE_PATH",
    "DATABASE_PATH"
  ]

  defp sanitize_prod_secrets(env) do
    # Add nil entries for each prod secret env var so they are explicitly
    # unset in the child process, even if inherited from the parent.
    stripped =
      for key <- @prod_secret_env_vars, reduce: env do
        acc ->
          # Remove any existing entry first
          Enum.reject(acc, fn {k, _v} -> k == key end)
      end

    # Append nil entries to unset in child process
    stripped ++ for key <- @prod_secret_env_vars, do: {key, nil}
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end

  defp safe_predicate(fun) do
    try do
      fun.() == true
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp application_started? do
    Enum.any?(Application.started_applications(), fn {app, _, _} ->
      app == :code_puppy_control
    end)
  end

  defp safe_discover_agents do
    try do
      AgentCatalogue.discover_agent_modules()
    catch
      _, _ -> :ok
    end
  end

  # Captures everything written to the calling process's group leader
  # while `fun` runs.  Returns `{captured_string, outcome}` where
  # `outcome` is one of:
  #
  #   * `{:ok, value}`            — `fun` returned `value`
  #   * `{:raised, exception}`    — `fun` raised an exception
  #   * `{:caught, {kind, why}}`  — `fun` threw or exited
  #
  # Uses `StringIO` + `Process.group_leader/2` so the lib does NOT pull
  # in `ExUnit.CaptureIO` at runtime (ExUnit is a test-only application
  # in production / Burrito builds).
  defp capture_group_leader(fun) do
    {:ok, sio} = StringIO.open("")
    prev_leader = Process.group_leader()
    Process.group_leader(self(), sio)

    outcome =
      try do
        {:ok, fun.()}
      rescue
        err -> {:raised, err}
      catch
        kind, why -> {:caught, {kind, why}}
      after
        Process.group_leader(self(), prev_leader)
      end

    {:ok, {_input, output}} = StringIO.close(sio)
    {output, outcome}
  end
end
