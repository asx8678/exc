defmodule CodePuppyControl.TUI.Input do
  # ── Constants ───────────────────────────────────────────────────────────

  @default_prompt "> "
  @max_history 100

  @moduledoc """
  Non-blocking terminal input.

  Provides a GenServer-based input loop that reads raw lines from stdin
  via `IO.gets/1` without blocking the TUI App. Supports:

    * Raw line-at-a-time input (delegates line editing to the terminal driver)
    * In-memory command history (add-only; navigation is handled by the App/Screen layer)
    * Graceful shutdown on EOF (`Ctrl+D`) or terminal errors

  ## Architecture

  The Input GenServer spawns a background `Task` that blocks on
  `IO.gets/1`. Each completed line is sent to the TUI App via
  `App.send_input/2`. This decouples the blocking IO read from the
  App's event loop. The prompt string is stored in state but the
  reader task reads with an empty string — the App/Screen is
  responsible for printing the prompt before each read.

  ## Supported Input

  The reader reads raw lines via `IO.gets/1`. Line editing (backspace,
  Ctrl+W, history navigation via up/down arrows) is provided by the
  underlying terminal driver (e.g., `erl_signal_server` or a library
  like `Owl` when available). The Input module itself does not implement
  line editing — it reads whatever the terminal delivers.

  ## History

  Commands are stored in a history buffer (max `#{@max_history}` entries).
  Consecutive duplicates are automatically deduplicated. History is
  returned newest-last (most recent final element).

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
    * `:start_reader` — whether to start the background reader task (default: `true`)
      Set to `false` in tests to avoid blocking on `IO.gets/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stop the input reader gracefully.

  Triggers `terminate/2` which shuts down the background reader task
  (if still alive) so the process exits cleanly without leaving a
  stranded `IO.gets/1` call.
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
    # Reversed on read since we prepend for O(1) append (see append_history/2)
    {:reply, Enum.reverse(state.history), state}
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

  @doc false
  # The reader runs in a separate Task to avoid blocking the GenServer.
  # It reads lines from IO.gets/1 and sends them to the Input GenServer.
  defp start_reader(input_server, _initial_prompt) do
    Task.start_link(fn ->
      reader_loop(input_server)
    end)
  end

  @doc false
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
  rescue
    # If IO.gets raises (e.g., group leader gone), exit gracefully
    e ->
      Logger.debug("Input reader: #{inspect(e)}")
      :ok
  end

  # ── History Management ─────────────────────────────────────────────────

  @doc false
  defp append_history(history, line) do
    # Prepend for O(1); reverse on read in handle_call(:history)
    new_history = [line | history]

    if length(new_history) > @max_history do
      Enum.drop(new_history, -1)
    else
      new_history
    end
  end
end
