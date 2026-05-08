defmodule CodePuppyControlWeb.Plugs.AdminAuthTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias CodePuppyControlWeb.Plugs.AdminAuth

  setup do
    # Snapshot/restore admin_ui config — these tests mutate it.
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    :ok
  end

  describe "allowed?/1" do
    test "loopback IPv4 is always allowed by default" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
      assert AdminAuth.allowed?({127, 0, 0, 1})
    end

    test "loopback IPv6 is always allowed by default" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
      assert AdminAuth.allowed?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "non-loopback IP is rejected by default" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
      refute AdminAuth.allowed?({10, 0, 0, 5})
    end

    test ":any allows everything" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :any)
      assert AdminAuth.allowed?({10, 0, 0, 5})
      assert AdminAuth.allowed?({1, 2, 3, 4})
      assert AdminAuth.allowed?({127, 0, 0, 1})
    end

    test "string allowlist permits matching IPs" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: ["10.0.0.42"])
      assert AdminAuth.allowed?({10, 0, 0, 42})
      refute AdminAuth.allowed?({10, 0, 0, 43})
      # Loopback always allowed even when an extra list is configured
      assert AdminAuth.allowed?({127, 0, 0, 1})
    end

    test "tuple allowlist permits matching IPs" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: [{192, 168, 1, 1}])
      assert AdminAuth.allowed?({192, 168, 1, 1})
      refute AdminAuth.allowed?({192, 168, 1, 2})
    end

    test "nil IP is allowed (LiveView dead-mount edge case)" do
      assert AdminAuth.allowed?(nil)
    end

    test "garbage allowlist value falls back to loopback-only" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :weird)
      assert AdminAuth.allowed?({127, 0, 0, 1})
      refute AdminAuth.allowed?({8, 8, 8, 8})
    end
  end

  describe "Plug.call/2" do
    test "passes a loopback request through" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)

      conn =
        :get
        |> conn("/admin")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> AdminAuth.call([])

      refute conn.halted
      refute conn.status == 403
    end

    test "rejects a non-loopback request with 403" do
      Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)

      conn =
        :get
        |> conn("/admin")
        |> Map.put(:remote_ip, {8, 8, 8, 8})
        |> AdminAuth.call([])

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "restricted"
    end
  end
end
