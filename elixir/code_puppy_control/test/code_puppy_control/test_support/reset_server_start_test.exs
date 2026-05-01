defmodule CodePuppyControl.TestSupport.Reset.ServerStartTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TestSupport.Reset.ServerStart

  @app_supervisor CodePuppyControl.Supervisor

  describe "ensure_gen_server_started/1" do
    test "restarts app-supervised ProviderRegistry under the application supervisor" do
      module = CodePuppyControl.ModelFactory.ProviderRegistry

      on_exit(fn -> ServerStart.ensure_gen_server_started(module) end)

      assert :ok = ServerStart.ensure_gen_server_started(module)
      assert :ok = Supervisor.terminate_child(@app_supervisor, module)
      assert Process.whereis(module) == nil

      assert :ok = ServerStart.ensure_gen_server_started(module)

      registered_pid = Process.whereis(module)
      assert is_pid(registered_pid)
      assert child_pid(@app_supervisor, module) == registered_pid
    end
  end

  describe "ensure_pubsub_started/0" do
    test "restarts PubSub through its application supervisor child id" do
      child_id = Phoenix.PubSub.Supervisor

      on_exit(fn -> ServerStart.ensure_pubsub_started() end)

      assert :ok = ServerStart.ensure_pubsub_started()
      assert :ok = Supervisor.terminate_child(@app_supervisor, child_id)
      assert Process.whereis(CodePuppyControl.PubSub) == nil

      assert :ok = ServerStart.ensure_pubsub_started()

      assert is_pid(Process.whereis(CodePuppyControl.PubSub))
      assert is_pid(child_pid(@app_supervisor, child_id))
    end
  end

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end
end
