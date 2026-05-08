defmodule CodePuppyControl.TUI.Renderer.DuplicateStartTest do
  @moduledoc """
  Regression tests for duplicate ToolCallStart on the same index.

  Verifies that a duplicate `%Event.ToolCallStart{index: idx}` is
  idempotent: the spinner ref is not overwritten, no second spinner
  is started, and the banner is not reprinted. A single subsequent
  `%Event.ToolCallEnd{index: idx}` cleanly stops the original spinner.

  This guards against the bug where the streaming layer published
  `tool_call_start` on provider `ToolCallEnd`, causing the TUI renderer
  to overwrite the spinner ref and lose the original spinner — leaving
  an orphaned spinner that never gets stopped.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Renderer

  # ---------------------------------------------------------------------------
  # Spy output module — uses an Agent to record calls across processes
  # ---------------------------------------------------------------------------

  defmodule SpyOutput do
    @moduledoc false
    @behaviour CodePuppyControl.TUI.Output

    @agent_name __MODULE__

    def start_agent do
      case Agent.start_link(fn -> [] end, name: @agent_name) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def stop_agent do
      try do
        Agent.stop(@agent_name)
      catch
        :exit, _ -> :ok
      end
    end

    def reset, do: Agent.update(@agent_name, fn _ -> [] end)

    def calls, do: Agent.get(@agent_name, & &1)

    defp log(call), do: Agent.update(@agent_name, &[call | &1])

    @impl true
    def puts(_data), do: :ok

    @impl true
    def banner(_label, _color, _icon), do: :ok

    @impl true
    def tool_banner(tool_name) do
      log({:tool_banner, tool_name})
      :ok
    end

    @impl true
    def start_spinner(loading_index, idx) do
      ref = make_ref()
      log({:start_spinner, loading_index, idx, ref})
      {ref, loading_index + 1}
    end

    @impl true
    def stop_spinner(ref) do
      log({:stop_spinner, ref})
      :ok
    end

    @impl true
    def stop_tool_spinner(spinner_ids, idx) do
      case Map.get(spinner_ids, idx) do
        nil ->
          spinner_ids

        ref ->
          stop_spinner(ref)
          Map.delete(spinner_ids, idx)
      end
    end

    @impl true
    def stop_all_spinners(spinner_ids) do
      Enum.each(spinner_ids, fn {_idx, ref} -> stop_spinner(ref) end)
      %{}
    end

    @impl true
    def color_background(color), do: color
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  setup do
    SpyOutput.start_agent()
    SpyOutput.reset()

    name = :"dup_start_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Renderer.start_link(name: name, output_mod: SpyOutput)

    on_exit(fn ->
      SpyOutput.stop_agent()
    end)

    {:ok, pid: pid, name: name}
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "duplicate ToolCallStart on same index" do
    test "start_spinner is called only once for the same index", %{pid: pid, name: name} do
      # First ToolCallStart — should start a spinner
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

      # Duplicate ToolCallStart on same index — should be ignored
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

      Process.sleep(20)

      start_calls =
        SpyOutput.calls()
        |> Enum.filter(fn
          {:start_spinner, _, _, _} -> true
          _ -> false
        end)

      # Only one start_spinner call, despite two ToolCallStart events
      assert length(start_calls) == 1

      Renderer.stop(pid)
    end

    test "banner is printed only once for duplicate ToolCallStart", %{pid: pid, name: name} do
      Renderer.push(name, %Event.ToolCallStart{index: 2, name: "grep"})
      Renderer.push(name, %Event.ToolCallStart{index: 2, name: "grep"})

      Process.sleep(20)

      banner_calls =
        SpyOutput.calls()
        |> Enum.filter(fn
          {:tool_banner, _} -> true
          _ -> false
        end)

      assert length(banner_calls) == 1
      assert {:tool_banner, "grep"} in banner_calls

      Renderer.stop(pid)
    end

    test "single ToolCallEnd stops the original spinner ref", %{pid: pid, name: name} do
      Renderer.push(name, %Event.ToolCallStart{index: 3, name: "read_file"})
      # Duplicate start — should be ignored
      Renderer.push(name, %Event.ToolCallStart{index: 3, name: "read_file"})

      # Single end — should stop the one spinner started by the first start
      Renderer.push(name, %Event.ToolCallEnd{
        index: 3,
        name: "read_file",
        id: "tc-3",
        arguments: "{}"
      })

      Process.sleep(20)

      calls = SpyOutput.calls()

      # Find the start_spinner call to get the ref
      [{:start_spinner, _loading_idx, _idx, original_ref}] =
        Enum.filter(calls, fn
          {:start_spinner, _, _, _} -> true
          _ -> false
        end)

      # stop_spinner should have been called with the original ref
      stop_calls =
        Enum.filter(calls, fn
          {:stop_spinner, _} -> true
          _ -> false
        end)

      assert length(stop_calls) == 1
      assert {:stop_spinner, ^original_ref} = hd(stop_calls)

      # Spinner should no longer be active for this index
      refute Renderer.spinner_active?(name, 3)

      Renderer.stop(pid)
    end

    test "spinner_ids does not grow on duplicate start", %{pid: pid, name: name} do
      Renderer.push(name, %Event.ToolCallStart{index: 4, name: "grep"})
      Process.sleep(20)
      assert Renderer.spinner_active?(name, 4)

      Renderer.push(name, %Event.ToolCallStart{index: 4, name: "grep"})
      Process.sleep(20)

      # Still only one spinner active (not two)
      assert Renderer.spinner_active?(name, 4)

      # Clean up
      Renderer.push(name, %Event.ToolCallEnd{
        index: 4,
        name: "grep",
        id: "tc-4",
        arguments: "{}"
      })

      Process.sleep(20)
      refute Renderer.spinner_active?(name, 4)

      Renderer.stop(pid)
    end

    test "different indices still get separate spinners", %{pid: pid, name: name} do
      Renderer.push(name, %Event.ToolCallStart{index: 5, name: "read_file"})
      # Duplicate on index 5 — ignored
      Renderer.push(name, %Event.ToolCallStart{index: 5, name: "read_file"})
      # Different index — should get its own spinner
      Renderer.push(name, %Event.ToolCallStart{index: 6, name: "grep"})

      Process.sleep(20)

      start_calls =
        SpyOutput.calls()
        |> Enum.filter(fn
          {:start_spinner, _, _, _} -> true
          _ -> false
        end)

      # Two spinners: one for index 5, one for index 6
      assert length(start_calls) == 2

      assert Renderer.spinner_active?(name, 5)
      assert Renderer.spinner_active?(name, 6)

      Renderer.stop(pid)
    end
  end
end
