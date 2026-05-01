defmodule CodePuppyControlWeb.Admin.JobDetailLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  test "redirects to /admin/jobs when the run_id does not exist", %{conn: conn} do
    # The redirect happens during mount(), so LiveView returns {:error, {:redirect, _}}.
    # (live_redirect is for push_patch/push_navigate from a connected view.)
    assert {:error, {:redirect, %{to: "/admin/jobs"} = redirect_info}} =
             live(conn, "/admin/jobs/no-such-run")

    assert redirect_info.flash["error"] =~ "not found"
  end
end
