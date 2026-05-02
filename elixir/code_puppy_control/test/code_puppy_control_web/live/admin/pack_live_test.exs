defmodule CodePuppyControlWeb.Admin.PackLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)

    # Start ClusterDashboard if not already running (needed by PackLive.mount/3)
    {:ok, dashboard_pid} =
      case GenServer.start(
             CodePuppyControl.Telemetry.ClusterDashboard,
             [],
             name: CodePuppyControl.Telemetry.ClusterDashboard
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    on_exit(fn ->
      Application.put_env(:code_puppy_control, :admin_ui, original)
      GenServer.stop(dashboard_pid, :normal, 1000)
    end)

    {:ok, conn: build_conn()}
  end

  test "renders pack chrome with semaphore stat cards", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/pack")
    assert html =~ "Pack"
    assert html =~ "Limit"
    assert html =~ "Active"
    assert html =~ "Available"
    assert html =~ "Waiters"
    assert has_element?(view, "a.active", "Pack")
  end

  test "shows the empty state when no active runs are holding slots", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/pack")
    assert html =~ "No active runs are holding pack slots right now."
  end

  test "PubSub event triggers a re-render", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/pack")
    send(view.pid, {:event, %{type: "status", run_id: "x", status: "running"}})
    assert render(view) =~ "Pack"
  end
end
