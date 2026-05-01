defmodule CodePuppyControl.Pack.RegistriesApplicationTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.Registries
  alias CodePuppyControl.Pack.RemoteNodeSupervisor
  alias CodePuppyControl.Pack.RemoteNodeProxy

  test "pack registries are started by application supervision tree" do
    assert is_pid(GenServer.whereis(Registries)),
           "CodePuppyControl.Pack.Registries should be started by the application tree"

    assert is_pid(GenServer.whereis(RemoteNodeSupervisor.Registry)),
           "RemoteNodeSupervisor.Registry should be started"

    assert is_pid(GenServer.whereis(RemoteNodeProxy.Registry)),
           "RemoteNodeProxy.Registry should be started"
  end
end
