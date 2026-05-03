defmodule CodePuppyControlWeb.Admin.SchedulerLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Ensure the AdminAuth plug allows our test conn
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  describe "mount and render" do
    test "renders scheduler page with stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/scheduler")

      assert html =~ "Scheduler"
      assert html =~ "CodePuppy Admin"
      assert html =~ "Total Tasks"
      assert html =~ "Enabled"
      assert html =~ "Disabled"
      assert html =~ "Runs (24h)"
    end

    test "shows empty state when no tasks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/scheduler")
      assert html =~ "No scheduled tasks configured."
    end

    test "sidebar marks Scheduler as active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/scheduler")
      assert has_element?(view, "a.active", "Scheduler")
    end
  end

  describe "real-time updates" do
    test "re-renders when a runtime event arrives via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/scheduler")

      # The LiveView is subscribed via Data.subscribe_global_events/0;
      # send a fake event and confirm we don't crash + still render.
      send(view.pid, {:event, %{type: "scheduler", task_id: 1, status: "completed"}})

      # Just rendering proves we processed the message without crashing.
      assert render(view) =~ "Scheduler"
    end

    test "ignores unknown messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/scheduler")
      send(view.pid, :something_random)
      send(view.pid, {:weird, "tuple"})
      assert render(view) =~ "Scheduler"
    end
  end
end
