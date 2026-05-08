defmodule CodePuppyControl.Callbacks.RegistryTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks.Registry

  setup do
    # (code_puppy-i1n) Ensure Registry is alive — it's a supervised
    # singleton that may be dead if a prior test killed the supervisor tree.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Registry)

    # Clear all callbacks before each test
    Registry.clear()
    :ok
  end

  describe "register/2" do
    test "registers a callback for a hook" do
      fun = fn -> :ok end
      assert :ok = Registry.register(:startup, fun)
      assert [^fun] = Registry.get_callbacks(:startup)
    end

    test "maintains registration order" do
      fun1 = fn -> :first end
      fun2 = fn -> :second end
      fun3 = fn -> :third end

      Registry.register(:startup, fun1)
      Registry.register(:startup, fun2)
      Registry.register(:startup, fun3)

      assert [^fun1, ^fun2, ^fun3] = Registry.get_callbacks(:startup)
    end

    test "idempotent — registering same function twice is a no-op" do
      fun = fn -> :ok end
      Registry.register(:startup, fun)
      Registry.register(:startup, fun)

      assert [^fun] = Registry.get_callbacks(:startup)
    end

    test "different hooks maintain separate callback lists" do
      fun1 = fn -> :startup end
      fun2 = fn -> :shutdown end

      Registry.register(:startup, fun1)
      Registry.register(:shutdown, fun2)

      assert [^fun1] = Registry.get_callbacks(:startup)
      assert [^fun2] = Registry.get_callbacks(:shutdown)
    end
  end

  describe "unregister/2" do
    test "removes a registered callback" do
      fun = fn -> :ok end
      Registry.register(:startup, fun)

      assert true = Registry.unregister(:startup, fun)
      assert [] = Registry.get_callbacks(:startup)
    end

    test "returns false when callback not found" do
      fun = fn -> :ok end
      assert false == Registry.unregister(:startup, fun)
    end

    test "only removes the specified callback" do
      fun1 = fn -> :first end
      fun2 = fn -> :second end

      Registry.register(:startup, fun1)
      Registry.register(:startup, fun2)

      assert true = Registry.unregister(:startup, fun1)
      assert [^fun2] = Registry.get_callbacks(:startup)
    end
  end

  describe "get_callbacks/1" do
    test "returns empty list for unregistered hook" do
      assert [] = Registry.get_callbacks(:nonexistent_hook)
    end
  end

  describe "count/1" do
    test "returns 0 for unregistered hook" do
      assert 0 = Registry.count(:startup)
    end

    test "returns correct count" do
      Registry.register(:startup, fn -> :a end)
      Registry.register(:startup, fn -> :b end)
      Registry.register(:shutdown, fn -> :c end)

      assert 2 = Registry.count(:startup)
      assert 1 = Registry.count(:shutdown)
    end

    test "counts all hooks with :all" do
      Registry.register(:startup, fn -> :a end)
      Registry.register(:startup, fn -> :b end)
      Registry.register(:shutdown, fn -> :c end)

      assert 3 = Registry.count(:all)
    end
  end

  describe "active_hooks/0" do
    test "returns empty list when no callbacks registered" do
      assert [] = Registry.active_hooks()
    end

    test "returns only hooks with callbacks" do
      Registry.register(:startup, fn -> :a end)
      Registry.register(:shutdown, fn -> :b end)

      hooks = Registry.active_hooks()
      assert :startup in hooks
      assert :shutdown in hooks
      refute :load_prompt in hooks
    end
  end

  describe "clear/1" do
    test "clears all callbacks with no argument" do
      Registry.register(:startup, fn -> :a end)
      Registry.register(:shutdown, fn -> :b end)

      assert :ok = Registry.clear()
      assert [] = Registry.get_callbacks(:startup)
      assert [] = Registry.get_callbacks(:shutdown)
    end

    test "clears only specified hook" do
      Registry.register(:startup, fn -> :a end)
      Registry.register(:shutdown, fn -> :b end)

      assert :ok = Registry.clear(:startup)
      assert [] = Registry.get_callbacks(:startup)
      assert [_] = Registry.get_callbacks(:shutdown)
    end
  end
end
