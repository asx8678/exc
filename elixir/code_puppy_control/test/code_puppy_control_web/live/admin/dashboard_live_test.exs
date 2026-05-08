defmodule CodePuppyControlWeb.Admin.DashboardLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Ensure the AdminAuth plug allows our test conn (which uses :any in tests
    # because Plug.Test sets remote_ip to {127,0,0,1}, but we belt-and-brace it).
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  describe "mount and render" do
    test "renders dashboard chrome with stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin")

      assert html =~ "Dashboard"
      assert html =~ "CodePuppy Admin"
      assert html =~ "Active jobs"
      assert html =~ "Pack slots"
      assert html =~ "Agents"
      assert html =~ "Worktrees"
      assert html =~ "Sessions"
    end

    test "shows the empty state when there are no recent jobs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin")
      # In the test env there are no live runs.
      assert html =~ "No runs yet"
    end

    test "sidebar marks Dashboard as active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")
      assert has_element?(view, "a.active", "Dashboard")
    end
  end

  describe "real-time updates" do
    test "re-renders when a runtime event arrives via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      # The LiveView is subscribed via Data.subscribe_global_events/0;
      # send a fake event and confirm we don't crash + still render.
      send(view.pid, {:event, %{type: "status", run_id: "fake-run", status: "running"}})

      # Just rendering proves we processed the message without crashing.
      assert render(view) =~ "Active jobs"
    end

    test "ignores unknown messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")
      send(view.pid, :something_random)
      send(view.pid, {:weird, "tuple"})
      assert render(view) =~ "Dashboard"
    end
  end
end
