defmodule CodePuppyControl.Pack.Worker.ApplicationTest do
  use ExUnit.Case, async: false

  describe "module structure" do
    test "Application uses Supervisor behaviour" do
      behaviours =
        CodePuppyControl.Pack.Worker.Application.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Supervisor in behaviours
    end

    test "start_link/1 is exported" do
      assert function_exported?(CodePuppyControl.Pack.Worker.Application, :start_link, 0)
      assert function_exported?(CodePuppyControl.Pack.Worker.Application, :start_link, 1)
    end

    test "start/2 Application callback is exported" do
      assert function_exported?(CodePuppyControl.Pack.Worker.Application, :start, 1)
      assert function_exported?(CodePuppyControl.Pack.Worker.Application, :start, 2)
    end
  end

  describe "SubAgentPool" do
    test "DynamicSupervisor starts and accepts children" do
      {:ok, pid} =
        DynamicSupervisor.start_link(
          name: CodePuppyControl.Pack.SubAgentPool,
          strategy: :one_for_one
        )

      assert Process.alive?(pid)

      # Verify it accepts children
      {:ok, _child} =
        DynamicSupervisor.start_child(
          CodePuppyControl.Pack.SubAgentPool,
          {Task, fn -> :timer.sleep(:infinity) end}
        )

      assert DynamicSupervisor.count_children(CodePuppyControl.Pack.SubAgentPool)[:active] == 1

      # Clean up
      DynamicSupervisor.stop(pid, :normal, 5000)
    end

    test "DynamicSupervisor :one_for_one strategy" do
      {:ok, pid} =
        DynamicSupervisor.start_link(
          name: CodePuppyControl.Pack.SubAgentPool,
          strategy: :one_for_one
        )

      # Start two tasks
      {:ok, t1} =
        DynamicSupervisor.start_child(
          CodePuppyControl.Pack.SubAgentPool,
          {Task, fn -> :timer.sleep(:infinity) end}
        )

      {:ok, t2} =
        DynamicSupervisor.start_child(
          CodePuppyControl.Pack.SubAgentPool,
          {Task, fn -> :timer.sleep(:infinity) end}
        )

      # Kill one — the other should survive
      Process.exit(t1, :kill)
      Process.sleep(50)

      assert Process.alive?(t2)
      assert DynamicSupervisor.count_children(CodePuppyControl.Pack.SubAgentPool)[:active] == 1

      DynamicSupervisor.stop(pid, :normal, 5000)
    end
  end

  describe "Worker child integration" do
    test "Pack.Worker starts independently with correct opts" do
      {:ok, pid} =
        CodePuppyControl.Pack.Worker.start_link(
          node_name: Node.self(),
          mode: :persistent,
          capabilities: %{sub_agents: [:terrier]}
        )

      assert Process.alive?(pid)

      # Verify capabilities are reported
      caps = GenServer.call(pid, :request_capabilities)
      assert caps.sub_agents == [:terrier]

      GenServer.stop(pid, :normal, 5000)
    end
  end
end
