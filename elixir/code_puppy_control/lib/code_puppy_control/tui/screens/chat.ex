defmodule CodePuppyControl.TUI.Screens.Chat do
  @moduledoc """
  Main chat interface screen.

  Displays conversation history with markdown rendering, shows the current
  agent and model in a header bar, and integrates with the TUI.Renderer for
  streaming responses.

  ## Input Handling

    * Regular text → sent to the agent loop as a user message
    * `/help` → switch to Help screen
    * `/config` → switch to Config screen
    * `/quit` → exit the TUI

  ## State

      %{
        session_id: String.t(),
        agent: module(),
        model: String.t(),
        messages: [%{role: atom(), content: String.t()}],
        renderer_pid: pid() | nil,
        status: :idle | :streaming
      }
  """

  @behaviour CodePuppyControl.TUI.Screen

  require Logger

  alias CodePuppyControl.TUI.Markdown
  alias CodePuppyControl.TUI.Renderer
  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.Config
  alias CodePuppyControl.SessionStorage

  # ── Types ──────────────────────────────────────────────────────────────────

  @type message :: %{role: :user | :assistant | :system, content: String.t()}

  @type state :: %{
          session_id: String.t(),
          agent: module(),
          model: String.t(),
          messages: [message()],
          renderer_pid: pid() | nil,
          status: :idle | :streaming
        }

  # ── Screen Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Map.get(opts, :session_id, generate_session_id())
    agent = Map.get(opts, :agent, CodePuppyControl.Agents.CodePuppy)
    model = Map.get(opts, :model, default_model())

    {:ok,
     %{
       session_id: session_id,
       agent: agent,
       model: model,
       messages: [],
       renderer_pid: nil,
       status: :idle
     }}
  end

  @impl true
  def render(state) do
    header = render_header(state)
    history = render_history(state.messages)
    prompt = render_prompt(state.status)

    [header, history, prompt]
  end

  @impl true
  def handle_input("", state), do: {:ok, state}

  def handle_input("/help", _state) do
    {:switch, CodePuppyControl.TUI.Screens.Help, %{}}
  end

  def handle_input("/config", _state) do
    {:switch, CodePuppyControl.TUI.Screens.Config, %{}}
  end

  def handle_input("/quit", _state), do: :quit

  def handle_input("/model " <> model_name, state) do
    {:ok, %{state | model: String.trim(model_name)}}
  end

  def handle_input("/clear", state) do
    {:ok, %{state | messages: []}}
  end

  def handle_input(input, %{status: :streaming} = state) do
    # Ignore input while streaming — could queue in the future
    _input = input
    {:ok, state}
  end

  def handle_input(input, state) do
    # Add user message to history
    user_msg = %{role: :user, content: input}
    new_messages = state.messages ++ [user_msg]

    # Set status to streaming and update messages immediately
    state = %{state | messages: new_messages, status: :streaming}

    # Trap exits for the entire critical section so that a linked process
    # crash (e.g., Agent.Loop) never kills the TUI.
    prev_trap = Process.flag(:trap_exit, true)

    try do
      dispatch_agent(state, new_messages)
    after
      Process.flag(:trap_exit, prev_trap)
      # Drain any :EXIT messages that arrived during the critical section
      receive do
        {:EXIT, _, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp dispatch_agent(state, new_messages) do
    # Start a Renderer for streaming output
    run_id = Loop.generate_run_id()
    renderer_name = {:via, Registry, {CodePuppyControl.REPL.RendererRegistry, state.session_id}}

    renderer_pid =
      case Renderer.start_link(name: renderer_name, session_id: state.session_id, run_id: run_id) do
        {:ok, pid} ->
          Process.unlink(pid)
          pid

        {:error, {:already_started, pid}} ->
          if Process.alive?(pid) do
            try do
              Renderer.reset(pid)
              pid
            catch
              :exit, _ -> start_fresh_renderer(state.session_id, run_id)
            end
          else
            start_fresh_renderer(state.session_id, run_id)
          end

        {:error, reason} ->
          Logger.warning("Chat: failed to start renderer: #{inspect(reason)}")
          nil
      end

    # Start the agent loop
    agent_module = state.agent

    loop_opts = [
      run_id: run_id,
      session_id: state.session_id,
      model: state.model
    ]

    try do
      case Loop.start_link(agent_module, new_messages, loop_opts) do
        {:ok, loop_pid} ->
          try do
            case Loop.run_until_done(loop_pid, :infinity) do
              :ok ->
                final_messages = Loop.get_messages(loop_pid)

                # Best-effort finalize renderer
                finalize_renderer(renderer_pid)

                # Persist messages to session storage (fire-and-forget)
                persist_messages(state.session_id, final_messages)

                {:ok, %{state | messages: final_messages, status: :idle, renderer_pid: nil}}

              {:error, reason} ->
                Logger.error("Chat: agent loop error: #{inspect(reason)}")
                finalize_renderer(renderer_pid)

                error_msg = %{role: :assistant, content: "Error: #{inspect(reason)}"}

                {:ok,
                 %{
                   state
                   | messages: new_messages ++ [error_msg],
                     status: :idle,
                     renderer_pid: nil
                 }}
            end
          after
            safe_stop_loop(loop_pid)
          end

        {:error, reason} ->
          Logger.error("Chat: failed to start agent loop: #{inspect(reason)}")
          finalize_renderer(renderer_pid)

          error_msg = %{
            role: :assistant,
            content: "Error: failed to start agent loop: #{inspect(reason)}"
          }

          {:ok,
           %{state | messages: new_messages ++ [error_msg], status: :idle, renderer_pid: nil}}
      end
    catch
      kind, reason ->
        Logger.error("Chat: agent loop crashed: #{inspect(kind)}: #{inspect(reason)}")
        finalize_renderer(renderer_pid)

        error_msg = %{role: :assistant, content: "Error: agent loop crashed — #{inspect(reason)}"}
        {:ok, %{state | messages: new_messages ++ [error_msg], status: :idle, renderer_pid: nil}}
    end
  end

  defp start_fresh_renderer(session_id, run_id) do
    renderer_name = {:via, Registry, {CodePuppyControl.REPL.RendererRegistry, session_id}}

    case Renderer.start_link(name: renderer_name, session_id: session_id, run_id: run_id) do
      {:ok, pid} ->
        Process.unlink(pid)
        pid

      {:error, _reason} ->
        nil
    end
  end

  defp finalize_renderer(nil), do: :ok

  defp finalize_renderer(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        Renderer.finalize(pid)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp safe_stop_loop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # Fire-and-forget session persistence. Normalizes atom-keyed Agent.Loop
  # messages to string-keyed format and saves asynchronously.
  defp persist_messages(session_id, messages) do
    normalized =
      messages
      |> Enum.map(fn
        %{role: role, content: content} when is_atom(role) ->
          %{"role" => Atom.to_string(role), "content" => content}

        %{role: role, content: content} when is_binary(role) ->
          %{"role" => role, "content" => content}

        other ->
          other
      end)

    SessionStorage.save_session_async(session_id, normalized, [])
  catch
    kind, reason ->
      Logger.warning("Chat: session persistence failed: #{inspect(kind)}: #{inspect(reason)}")
      :ok
  end

  @impl true
  def cleanup(state) do
    if state.renderer_pid && Process.alive?(state.renderer_pid) do
      # Best-effort stop of the renderer
      try do
        CodePuppyControl.TUI.Renderer.stop(state.renderer_pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── Rendering Helpers ──────────────────────────────────────────────────────

  defp render_header(state) do
    agent_name = agent_display_name(state.agent)
    status_icon = if state.status == :streaming, do: "⏳", else: "🐾"
    status_text = if state.status == :streaming, do: "streaming", else: "idle"

    title = " #{status_icon} Code Puppy — #{agent_name} @ #{state.model} "
    right = " [#{status_text}] "

    Owl.Box.new(
      [Owl.Data.tag(title, :cyan), Owl.Data.tag(right, :faint)],
      min_width: 60,
      border: :bottom,
      border_color: :cyan
    )
  end

  defp render_history([]) do
    Owl.Data.tag("\n No messages yet. Type something to start chatting!\n", :faint)
  end

  defp render_history(messages) do
    rendered =
      messages
      |> Enum.map(&render_message/1)
      |> Enum.intersperse("\n")

    [rendered, "\n"]
  end

  defp render_message(%{role: :user, content: content}) do
    label = Owl.Data.tag(" YOU ", [:white, :blue_background])
    [label, " ", content, "\n"]
  end

  defp render_message(%{role: :assistant, content: content}) do
    label = Owl.Data.tag(" 🐶 ", [:white, :green_background])
    rendered_content = Markdown.render(content)
    [label, " ", rendered_content, "\n"]
  end

  defp render_message(%{role: :system, content: content}) do
    label = Owl.Data.tag(" SYS ", [:white, :yellow_background])
    [label, " ", Owl.Data.tag(content, :faint), "\n"]
  end

  defp render_message(%{role: role, content: content}) do
    label = Owl.Data.tag(" #{role} ", [:white, :magenta_background])
    [label, " ", content, "\n"]
  end

  defp render_prompt(:streaming) do
    Owl.Data.tag(" ⏳ Waiting for response... (input ignored)\n", :faint)
  end

  defp render_prompt(:idle) do
    Owl.Data.tag(" > ", :cyan)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp default_model do
    try do
      Config.Models.global_model_name() || "unknown"
    catch
      _, _ -> "unknown"
    end
  end

  defp agent_display_name(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
    |> String.replace_suffix("", "")
  end

  defp agent_display_name(other), do: inspect(other)
end
