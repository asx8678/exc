defmodule CodePuppyControl.TUI.InputTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Input

  # ── Test App Receiver ───────────────────────────────────────────────────

  @doc false
  defmodule TestAppReceiver do
    @moduledoc false
    use GenServer

    @impl true
    def init(_opts) do
      {:ok, %{inputs: []}}
    end

    @impl true
    def handle_call(:inputs, _from, state) do
      {:reply, state.inputs, state}
    end

    @impl true
    def handle_cast({:input, input}, state) do
      {:noreply, %{state | inputs: state.inputs ++ [input]}}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp with_test_app do
    {:ok, pid} = GenServer.start_link(TestAppReceiver, %{}, [])
    pid
  end

  defp start_input(opts \\ []) do
    name =
      Keyword.get_lazy(opts, :name, fn ->
        :"input_test_#{System.unique_integer([:positive])}"
      end)

    {:ok, pid} =
      Input.start_link(
        Keyword.merge(
          [
            app: CodePuppyControl.TUI.App,
            start_reader: false
          ],
          opts
        ) ++ [name: name]
      )

    {pid, name}
  end

  # ── Lifecycle ───────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts with default options" do
      {pid, _name} = start_input()
      assert Process.alive?(pid)
      Input.stop(pid)
    end

    test "starts with custom prompt" do
      {pid, _name} = start_input(prompt: "puppy> ")
      assert Process.alive?(pid)
      Input.stop(pid)
    end
  end

  # ── history management ──────────────────────────────────────────────────

  describe "history/1" do
    test "starts with empty history" do
      {pid, name} = start_input()
      assert Input.history(name) == []
      Input.stop(pid)
    end
  end

  describe "clear_history/1" do
    test "clears history without crashing" do
      {pid, name} = start_input()
      :ok = Input.clear_history(name)
      assert Input.history(name) == []
      Input.stop(pid)
    end
  end

  # ── set_prompt/1 ────────────────────────────────────────────────────────

  describe "set_prompt/2" do
    test "updates prompt without crashing" do
      {pid, name} = start_input()
      :ok = Input.set_prompt(name, "(config)> ")
      Input.stop(pid)
    end
  end

  # ── stop/1 ──────────────────────────────────────────────────────────────

  describe "stop/1" do
    test "stops gracefully" do
      {pid, name} = start_input()
      assert Process.alive?(pid)
      :ok = Input.stop(name)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  # ── Input Forwarding ────────────────────────────────────────────────────

  describe "input forwarding" do
    test "forwards input to the app via cast" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      GenServer.cast(name, {:input, "hello"})

      # Drain Input's mailbox (cast is async) before checking the app
      :sys.get_state(name)

      assert GenServer.call(app_pid, :inputs) == ["hello"]
      Input.stop(pid)
    end

    test "eof stops the reader and sends quit to the app" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      GenServer.cast(name, {:eof, :eof})

      # :sys.get_state synchronises with the process
      state = :sys.get_state(name)
      refute state.running, "expected running to be false after EOF"

      # Verify the App received the quit command
      assert GenServer.call(app_pid, :inputs) == ["quit"]
      Input.stop(pid)
    end
  end

  # ── History Management (with actual entries) ───────────────────────────

  describe "history with entries" do
    test "append_history accumulates entries in order" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      GenServer.cast(name, {:input, "first"})
      GenServer.cast(name, {:input, "second"})
      GenServer.cast(name, {:input, "third"})

      assert Input.history(name) == ["first", "second", "third"]
      Input.stop(pid)
    end

    test "consecutive duplicate lines are deduplicated" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      GenServer.cast(name, {:input, "repeat"})
      GenServer.cast(name, {:input, "repeat"})

      assert Input.history(name) == ["repeat"]
      Input.stop(pid)
    end

    test "non-consecutive duplicates are kept" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      GenServer.cast(name, {:input, "a"})
      GenServer.cast(name, {:input, "b"})
      GenServer.cast(name, {:input, "a"})

      assert Input.history(name) == ["a", "b", "a"]
      Input.stop(pid)
    end

    test "clear_history works after entries have been added" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      GenServer.cast(name, {:input, "something"})

      # Synchronise before clearing
      _ = Input.history(name)

      Input.clear_history(name)
      assert Input.history(name) == []
      Input.stop(pid)
    end

    test "set_prompt updates the prompt in GenServer state" do
      {pid, name} = start_input()

      Input.set_prompt(name, "(config)> ")

      state = :sys.get_state(name)
      assert state.prompt == "(config)> "
      Input.stop(pid)
    end
  end

  # ── Reader Task Lifecycle ───────────────────────────────────────────────

  describe "reader task" do
    test "init starts reader_task when start_reader is true" do
      {_pid, name} = start_input(start_reader: true)

      state = :sys.get_state(name)

      assert is_pid(state.reader_task),
             "expected reader_task to be a PID, got: #{inspect(state.reader_task)}"

      assert Process.alive?(state.reader_task), "expected reader_task to be alive"

      Input.stop(name)
    end

    test "terminate shuts down the reader task on stop" do
      {_pid, name} = start_input(start_reader: true)

      state = :sys.get_state(name)
      reader_pid = state.reader_task

      assert Process.alive?(reader_pid),
             "pre-condition: reader_task should be alive before stop"

      :ok = Input.stop(name)
      Process.sleep(10)

      refute Process.alive?(reader_pid)
    end

    test "reader_loop reads input lines from stdin and forwards them" do
      app_pid = with_test_app()

      {:ok, string_io} = StringIO.open("hello\nworld\n")

      {pid, name} =
        Task.await(
          Task.async(fn ->
            # Redirect this task's stdin to the StringIO device;
            # the Input GenServer (and its reader task) inherit this
            :erlang.group_leader(string_io, self())

            name = :"input_reader_io_#{System.unique_integer([:positive])}"

            {:ok, pid} =
              Input.start_link(
                app: app_pid,
                start_reader: true,
                name: name
              )

            # Allow the reader task to process input
            Process.sleep(50)

            {pid, name}
          end),
          2000
        )

      # Lines are forwarded to Input history
      assert Input.history(name) == ["hello", "world"]

      # Input is also forwarded to the App; after exhausting the
      # StringIO, the reader sends :eof → App gets a "quit" too
      app_inputs = GenServer.call(app_pid, :inputs)
      assert app_inputs == ["hello", "world", "quit"]

      Input.stop(pid)
    end
  end

  # ── max_history trimming ────────────────────────────────────────────────

  describe "history max capacity" do
    test "trims oldest entry when history exceeds @max_history" do
      app_pid = with_test_app()
      {pid, name} = start_input(app: app_pid)

      # Add 101 unique entries (max_history defaults to 100)
      for i <- 0..100 do
        GenServer.cast(name, {:input, "entry #{i}"})
      end

      # Synchronise and check
      history = Input.history(name)

      assert length(history) == 100

      assert Enum.at(history, 0) == "entry 1",
             "expected 'entry 0' to have been trimmed, first entry is #{inspect(Enum.at(history, 0))}"

      assert Enum.at(history, 99) == "entry 100"
      Input.stop(pid)
    end
  end
end
