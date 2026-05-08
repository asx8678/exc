defmodule CodePuppyControl.REPL.Loop do
  @moduledoc """
  Interactive REPL loop for Code Puppy.

  Handles the read-eval-print cycle:
  1. Display prompt with context (agent, model, session)
  2. Read user input (with history/multiline support via REPL.Input)
  3. Process input (slash commands or agent prompts)
  4. Display output via TUI.Renderer
  5. Repeat

  ## Architecture

  The REPL loop can operate in two modes:

  - **Blocking** (`run/1`) — The main CLI entry point. Blocks the calling
    process in a tight read-eval loop until `/quit` or EOF.
  - **GenServer** (`start_link/1`) — For supervision and hot code reload.
    The GenServer drives the same loop via `handle_continue/2`.

  ## Slash Commands (Phase 1)

    * `/help` — Show available commands
    * `/quit` — Exit the REPL
    * `/exit` — Alias for /quit
    * `/model` — Interactive model selection
    * `/model <name>` — Switch model directly
    * `/agent` — Interactive agent selection
    * `/agent <name>` — Switch agent directly
    * `/sessions` — Browse and switch sessions
    * `/tui` — Launch full TUI interface
    * `/clear` — Clear the terminal screen
    * `/history` — Show command history

  Phase 2-3 will add tab completion, raw-mode key handling,
  and more commands.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.CLI.SlashCommands.Dispatcher
  alias CodePuppyControl.Config.Models
  alias CodePuppyControl.REPL.Dispatch
  alias CodePuppyControl.REPL.Input
  alias CodePuppyControl.REPL.History
  alias CodePuppyControl.Tools.AgentCatalogue
  alias CodePuppyControl.TUI.Widgets.AgentSelector
  alias CodePuppyControl.TUI.Widgets.ModelSelector
  alias CodePuppyControl.TUI.Widgets.SessionBrowser
  alias CodePuppyControl.TUI.App

  # ── State ──────────────────────────────────────────────────────────────────

  defstruct [
    :session_id,
    agent: "code-puppy",
    model: nil,
    running: true
  ]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          agent: String.t(),
          model: String.t() | nil,
          running: boolean()
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the REPL loop GenServer.

  ## Options

    * `:agent` — Initial agent name (default: "code-puppy")
    * `:model` — Initial model override (default: from config)
    * `:session_id` — Session identifier
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Blocking REPL loop for CLI use.

  This is the main entry point from `CLI.run_interactive/1`.
  Runs the read-eval-print loop until `/quit`, `/exit`, or EOF.
  Does NOT start a GenServer — runs inline in the calling process.
  """
  @spec run(map()) :: :ok
  def run(opts) when is_map(opts) do
    # Use || so that explicit nil from CLI parser falls back to default.
    agent = opts[:agent] || "code-puppy"
    model = Map.get(opts, :model) || Models.global_model_name()
    session_id = Map.get(opts, :session_id) || generate_session_id()

    state = %__MODULE__{
      agent: agent,
      model: model,
      session_id: session_id,
      running: true
    }

    # Ensure History GenServer is running and loaded
    ensure_history_started()
    History.load()

    print_welcome(state)
    do_loop(state)
  end

  @doc """
  Process a single line of input through the REPL.

  Returns `{:continue, state}` to keep looping, or `{:halt, state}` to exit.
  Separated from the loop for testability.
  """
  @spec handle_input(String.t(), t()) :: {:continue, t()} | {:halt, t()}
  def handle_input(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:continue, state}

      is_slash_command?(trimmed) ->
        execute_slash_command(trimmed, state)

      is_shell_passthrough?(trimmed) ->
        execute_shell_passthrough(trimmed, state)
        {:continue, state}

      true ->
        History.add(trimmed)
        send_to_agent(trimmed, state)
        {:continue, state}
    end
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    agent = Keyword.get(opts, :agent, "code-puppy")
    model = Keyword.get(opts, :model) || Models.global_model_name()
    session_id = Keyword.get(opts, :session_id) || generate_session_id()

    state = %__MODULE__{
      agent: agent,
      model: model,
      session_id: session_id,
      running: true
    }

    {:ok, state, {:continue, :loop}}
  end

  @impl true
  def handle_continue(:loop, %{running: false} = state) do
    {:stop, :normal, state}
  end

  def handle_continue(:loop, state) do
    prompt = Input.display_prompt(agent: state.agent, model: state.model)

    case Input.read_multiline(prompt, agent: state.agent, model: state.model) do
      {:ok, line} ->
        case handle_input(line, state) do
          {:continue, new_state} ->
            {:noreply, new_state, {:continue, :loop}}

          {:halt, new_state} ->
            {:stop, :normal, %{new_state | running: false}}
        end

      :eof ->
        IO.puts("\n👋 Bye!")
        {:stop, :normal, %{state | running: false}}

      {:error, reason} ->
        Logger.error("REPL input error: #{inspect(reason)}")
        {:stop, {:error, reason}, state}
    end
  end

  # ── Slash Command Detection ────────────────────────────────────────────────

  @doc """
  Returns true if the input line starts with `/` (slash command).
  Delegates to `Dispatcher.is_slash_command?/1`.
  """
  @spec is_slash_command?(String.t()) :: boolean()
  def is_slash_command?(line), do: Dispatcher.is_slash_command?(line)

  # ── Slash Command Execution ───────────────────────────────────────────────

  @spec execute_slash_command(String.t(), t()) :: {:continue, t()} | {:halt, t()}
  defp execute_slash_command(line, state) do
    case Dispatcher.dispatch(line, state) do
      {:ok, {:continue, new_state}} ->
        {:continue, new_state}

      {:ok, {:halt, new_state}} ->
        {:halt, new_state}

      {:error, :unknown_command} ->
        # Extract command name for the error message
        cmd = line |> String.split(" ", parts: 2) |> hd()
        IO.puts(IO.ANSI.red() <> "Unknown command: #{cmd}" <> IO.ANSI.reset())
        IO.puts("Type /help for available commands.")
        {:continue, state}

      {:error, :not_a_slash_command} ->
        # Shouldn't happen since we gate on is_slash_command?
        {:continue, state}
    end
  end

  # ── Command Handlers ──────────────────────────────────────────────────────

  @doc false
  # Public for delegation from CLI.SlashCommands.Commands.Context
  def handle_model_command("", state) do
    # Interactive model selection via ModelSelector widget
    # Falls back to showing current model if selection is unavailable
    try do
      case ModelSelector.select(default: state.model) do
        {:ok, model_name} ->
          IO.puts("Switching model: #{state.model} → #{model_name}")

          try do
            :ok = Models.set_global_model(model_name)
          catch
            :exit, _ -> :ok
          end

          {:continue, %{state | model: model_name}}

        :cancelled ->
          IO.puts("Model selection cancelled.")
          {:continue, state}
      end
    rescue
      _ ->
        # ModelSelector may fail in non-TTY environments
        IO.puts("Current model: #{state.model}")
        {:continue, state}
    end
  end

  def handle_model_command(model_name, state) do
    model_name = String.trim(model_name)
    IO.puts("Switching model: #{state.model} → #{model_name}")

    # Persist the change (best-effort; Config.Writer may not be running in test)
    try do
      :ok = Models.set_global_model(model_name)
    catch
      :exit, _ -> :ok
    end

    {:continue, %{state | model: model_name}}
  end

  @doc false
  # Public for delegation from CLI.SlashCommands.Commands.Context
  def handle_agent_command("", state) do
    # Interactive agent selection via AgentSelector widget
    # Falls back to showing current agent if selection is unavailable
    try do
      case AgentSelector.select(default: state.agent) do
        {:ok, agent_slug} ->
          IO.puts("Switching agent: #{state.agent} → #{agent_slug}")
          {:continue, %{state | agent: agent_slug}}

        :cancelled ->
          IO.puts("Agent selection cancelled.")
          {:continue, state}
      end
    rescue
      _ ->
        # AgentSelector may fail in non-TTY environments
        IO.puts("Current agent: #{state.agent}")
        {:continue, state}
    end
  end

  def handle_agent_command(agent_name, state) do
    agent_name = String.trim(agent_name)

    # Resolve through the catalogue to get the canonical kebab-case slug.
    # If the agent is known, store the canonical slug; otherwise fall back
    # to the raw input so the REPL doesn't reject unknown names outright.
    canonical_slug =
      case resolve_agent_key(agent_name) do
        {:ok, key} -> String.replace(key, "_", "-")
        {:error, _} -> agent_name
      end

    IO.puts("Switching agent: #{state.agent} → #{canonical_slug}")
    {:continue, %{state | agent: canonical_slug}}
  end

  # ── Sessions Command ────────────────────────────────────────────────────

  @doc false
  # Public for delegation from CLI.SlashCommands.Commands.Context
  def handle_sessions_command("", state) do
    # Launch interactive session browser
    try do
      case SessionBrowser.browse() do
        {:ok, session_name} ->
          IO.puts("Switching to session: #{session_name}")
          {:continue, %{state | session_id: session_name}}

        {:delete, session_name} ->
          IO.puts("Session deletion requested: #{session_name}")
          {:continue, state}

        {:preview, session_name} ->
          IO.puts("Session preview: #{session_name}")
          {:continue, state}

        :cancelled ->
          IO.puts("Session browser cancelled.")
          {:continue, state}
      end
    rescue
      _ ->
        IO.puts("Session browser unavailable (database not ready).")
        {:continue, state}
    end
  end

  def handle_sessions_command(args, state) do
    # With arguments, just invoke browse with filter
    try do
      case SessionBrowser.browse(filter: String.trim(args)) do
        {:ok, session_name} ->
          IO.puts("Switching to session: #{session_name}")
          {:continue, %{state | session_id: session_name}}

        {:delete, _name} ->
          {:continue, state}

        {:preview, _name} ->
          {:continue, state}

        :cancelled ->
          {:continue, state}
      end
    rescue
      _ ->
        IO.puts("Session browser unavailable (database not ready).")
        {:continue, state}
    end
  end

  # ── TUI Command ────────────────────────────────────────────────────────

  @doc false
  # Public for delegation from CLI.SlashCommands.Commands.Context
  def handle_tui_command(state) do
    IO.puts("Launching TUI...")

    try do
      {:ok, _pid} =
        App.start_link(
          screen: CodePuppyControl.TUI.Screens.Chat,
          screen_opts: %{
            session_id: state.session_id,
            model: state.model
          }
        )

      {:continue, state}
    catch
      :exit, reason ->
        IO.puts(IO.ANSI.red() <> "Failed to launch TUI: #{inspect(reason)}" <> IO.ANSI.reset())
        {:continue, state}
    end
  end

  # ── Shell Passthrough ─────────────────────────────────────────────────────

  @doc """
  Returns true if the input line is a shell passthrough (`!command`).
  """
  @spec is_shell_passthrough?(String.t()) :: boolean()
  def is_shell_passthrough?("!" <> _), do: true
  def is_shell_passthrough?(_), do: false

  defp execute_shell_passthrough("!" <> cmd, _state) do
    # Run the shell command and display output
    case System.shell(cmd, stderr_to_stdout: true) do
      {output, 0} ->
        IO.puts(output)

      {output, exit_code} ->
        IO.puts(IO.ANSI.red() <> "Exit code: #{exit_code}" <> IO.ANSI.reset())
        IO.puts(output)
    end
  end

  # ── Agent Prompt Dispatch ─────────────────────────────────────────────────

  defp send_to_agent(prompt, state) do
    Logger.debug("REPL: send_to_agent agent=#{state.agent} model=#{state.model}")

    # Phase 1: resolve agent + ensure state — no state mutation, so no
    # rollback needed if these fail.
    with {:ok, agent_key, agent_module} <- resolve_agent_module(state.agent),
         :ok <- ensure_agent_state_for(state.session_id, agent_key) do
      # Phase 2: snapshot, append user message, then dispatch. Any failure
      # after the append MUST roll back so the user message is not orphaned.
      messages_before = State.get_messages(state.session_id, agent_key)

      user_msg = %{"role" => "user", "parts" => [%{"type" => "text", "text" => prompt}]}
      :ok = State.append_message(state.session_id, agent_key, user_msg)

      Dispatch.dispatch_after_append(state, agent_key, agent_module, messages_before)
    else
      {:error, {:unknown_agent, name}} ->
        Dispatch.print_agent_error("Unknown agent: #{name}. Use /agent to switch.")
        :error

      {:error, :no_module} ->
        Dispatch.print_agent_error(
          "Agent \"#{state.agent}\" has no backing module. Use /agent to switch."
        )

        :error

      {:error, reason} ->
        Dispatch.print_agent_error("Agent dispatch failed: #{inspect(reason)}")
        :error
    end
  end

  # ── Agent Dispatch Helpers ────────────────────────────────────────────────

  @doc """
  Resolves the Agent.State key for the given display name.

  Tries the name as-given, then kebab↔snake variants, returning
  the first key that matches in the AgentCatalogue. This is the
  canonical key used for `Agent.State` operations.

  Returns `{:ok, agent_key}` or `{:error, reason}`.
  """
  @spec resolve_agent_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_agent_key(agent_name) when is_binary(agent_name) do
    case resolve_agent_module(agent_name) do
      {:ok, key, _module} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Public for REPL.OneShot dispatch; also used internally by resolve_agent_key/1.
  def resolve_agent_module(agent_name) when is_binary(agent_name) do
    # Try the name as-given, then kebab↔snake variants. AgentCatalogue keys
    # are typically snake_case internally even when the UI shows kebab-case.
    candidates =
      [agent_name, String.replace(agent_name, "-", "_"), String.replace(agent_name, "_", "-")]
      |> Enum.uniq()

    Enum.reduce_while(candidates, {:error, {:unknown_agent, agent_name}}, fn candidate, acc ->
      case safe_catalogue_lookup(candidate) do
        {:ok, module} when is_atom(module) ->
          {:halt, {:ok, candidate, module}}

        :not_found ->
          {:cont, acc}

        {:error, :no_module} ->
          {:halt, {:error, :no_module}}

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp safe_catalogue_lookup(name) do
    try do
      case AgentCatalogue.get_agent_module(name) do
        :not_found -> discover_agent_module(name)
        other -> other
      end
    rescue
      _ -> discover_agent_module(name)
    end
  end

  defp discover_agent_module(name) when is_binary(name) do
    AgentCatalogue.discover_agent_modules()
    |> Enum.find_value(:not_found, fn {module, agent_name, _display_name, _description} ->
      if to_string(agent_name) == name, do: {:ok, module}, else: false
    end)
  rescue
    _ -> :not_found
  end

  @doc false
  # Public for REPL.OneShot dispatch; also used internally by send_to_agent/2.
  def ensure_agent_state_for(session_id, agent_key) do
    case State.start_agent_state(session_id, agent_key) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── History ────────────────────────────────────────────────────────────────

  # print_history/0 moved to CLI.SlashCommands.Commands.Core.handle_history/2

  defp ensure_history_started do
    case Process.whereis(History) do
      nil ->
        {:ok, _pid} = History.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  # ── Welcome & Help ─────────────────────────────────────────────────────────

  defp print_welcome(state) do
    IO.puts("""

    🐶 Code Puppy — Interactive Mode
    ─────────────────────────────────
    Agent: #{state.agent}
    Model: #{state.model}
    Session: #{state.session_id}

    Type /help for commands, /quit to exit.
    """)
  end

  # print_help/0 moved to CLI.SlashCommands.Commands.Core.handle_help/2

  # ── Main Loop ──────────────────────────────────────────────────────────────

  defp do_loop(%{running: false} = state), do: state

  defp do_loop(state) do
    prompt = Input.display_prompt(agent: state.agent, model: state.model)

    case Input.read_multiline(prompt, agent: state.agent, model: state.model) do
      {:ok, line} ->
        case handle_input(line, state) do
          {:continue, new_state} ->
            do_loop(new_state)

          {:halt, new_state} ->
            new_state
        end

      :eof ->
        IO.puts("\n👋 Bye!")
        state

      {:error, reason} ->
        Logger.error("REPL input error: #{inspect(reason)}")
        state
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp generate_session_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
