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

  alias CodePuppyControl.TUI.Markdown
  alias CodePuppyControl.Config

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
    agent = Map.get(opts, :agent, CodePuppyControl.Agent.Behaviour)
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

    # TODO(prg-3): Wire to Agent.Loop.run_turn/1 for real agent invocation.
    # For now, record the message and echo a placeholder assistant response.
    assistant_msg = %{role: :assistant, content: "(agent not yet wired — you said: #{input})"}
    final_messages = new_messages ++ [assistant_msg]

    {:ok, %{state | messages: final_messages}}
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
