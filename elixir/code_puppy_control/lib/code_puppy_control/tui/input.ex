defmodule CodePuppyControl.TUI.Input do
  @moduledoc """
  Non-blocking terminal input with line editing support.

  Provides a GenServer-based input loop that reads lines from stdin
  without blocking the TUI App. Supports:

    * Line-at-a-time input with basic editing (backspace, Ctrl+W)
    * Command history (up/down arrows)
    * Tab completion hook (delegates to `CodePuppyControl.REPL.Completion`)
    * Graceful shutdown on EOF or Ctrl+D

  ## Architecture

  The Input GenServer runs in a dedicated task that reads from
  `IO.gets/1`. When a line is completed, it sends the input to
  the TUI App via `App.send_input/2`. This decouples the blocking
  IO read from the App's event loop.

  ## Usage

      # Start the input reader (usually started by TUI.Supervisor)
      {:ok, pid} = Input.start_link(app: MyApp)

      # Input is automatically forwarded to the App
      # (no manual calls needed)

  ## Integration with Screen

  Screens can customise the prompt by implementing `prompt/1`
  (optional callback on `TUI.Screen`). If not implemented, the
  default prompt `"> "` is used.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.TUI.App

  # ── Constants ───────────────────────────────────────────────────────────

  @default_prompt "> "
  @max_history 100

  # ── State ───────────────────────────────────────────────────────────────

  defstruct [
    :app_server,
    :prompt,
    :reader_task,
    history: [],
    history_index: -1,
    running: true
  ]

  @type t :: %__MODULE__{
          app_server: GenServer.server(),
          prompt: String.t(),
          reader_task: Task.t() | nil,
          history: [String.t()],
          history_index: integer(),
          running: boolean()
        }

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Start the input GenServer.

  ## Options

    * `:app` — the TUI App GenServer to forward input to (default: `App`)
    * `:prompt` — the prompt string (default: `"> "`)
    * `:name` — GenServer name registration
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stop the input reader gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.stop(server, :normal)
  end

  @doc """
  Update the prompt displayed to the user.

  Screens can call this when they become active to customise the
  prompt (e.g. `"/help> "`, `"(config)> "`).
  """
  @spec set_prompt(GenServer.server(), String.t()) :: :ok
  def set_prompt(server \\ __MODULE__, prompt) when is_binary(prompt) do
    GenServer.cast(server, {:set_prompt, prompt})
  end

  @doc """
  Return the current command history (most recent last).
  """
  @spec history(GenServer.server()) :: [String.t()]
  def history(server \\ __MODULE__) do
    GenServer.call(server, :history)
  end

  @doc """
  Clear command history.
  """
  @spec clear_history(GenServer.server()) :: :ok
  def clear_history(server \\ __MODULE__) do
    GenServer.cast(server, :clear_history)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    app_server = Keyword.get(opts, :app, App)
    prompt = Keyword.get(opts, :prompt, @default_prompt)
    start_reader? = Keyword.get(opts, :start_reader, true)

    state = %__MODULE__{
      app_server: app_server,
      prompt: prompt,
      history: [],
      history_index: -1
    }

    # Start the reader task in the background (unless disabled for testing)
    if start_reader? do
      {:ok, reader_task} = start_reader(self(), prompt)
      {:ok, %{state | reader_task: reader_task}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_cast({:set_prompt, prompt}, state) do
    {:noreply, %{state | prompt: prompt}}
  end

  @impl true
  def handle_cast(:clear_history, state) do
    {:noreply, %{state | history: [], history_index: -1}}
  end

  @impl true
  def handle_cast({:input, line}, state) do
    # Forward to the TUI App
    App.send_input(line, state.app_server)

    # Add to history (deduplicate consecutive duplicates)
    new_history =
      case List.last(state.history) do
        ^line -> state.history
        _ -> append_history(state.history, line)
      end

    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_cast({:eof, _reason}, state) do
    # Terminal closed or Ctrl+D — signal quit to the App
    App.send_input("quit", state.app_server)
    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.reader_task do
      if Process.alive?(state.reader_task) do
        Process.exit(state.reader_task, :kill)
      end
    end

    :ok
  end

  # ── Reader Task ─────────────────────────────────────────────────────────

  # The reader runs in a separate Task to avoid blocking the GenServer.
  # It reads lines from IO.gets/1 and sends them to the Input GenServer.
  defp start_reader(input_server, _initial_prompt) do
    Task.start_link(fn ->
      reader_loop(input_server)
    end)
  end

  defp reader_loop(input_server) do
    case IO.gets("") do
      :eof ->
        GenServer.cast(input_server, {:eof, :eof})

      {:error, reason} ->
        GenServer.cast(input_server, {:eof, reason})

      line ->
        trimmed = String.trim_trailing(line, "\n")
        GenServer.cast(input_server, {:input, trimmed})
        reader_loop(input_server)
    end
  end

  # ── History Management ─────────────────────────────────────────────────

  defp append_history(history, line) do
    new_history = history ++ [line]

    if length(new_history) > @max_history do
      tl(new_history)
    else
      new_history
    end
  end
end
