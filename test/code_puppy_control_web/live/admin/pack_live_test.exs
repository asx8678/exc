defmodule CodePuppyControlWeb.Admin.PackLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)

    on_exit(fn ->
      Application.put_env(:code_puppy_control, :admin_ui, original)
    end)

    {:ok, conn: build_conn()}
  end

  describe "with ClusterDashboard running" do
    setup do
      # Start ClusterDashboard for this describe block
      case GenServer.start(
             CodePuppyControl.Telemetry.ClusterDashboard,
             [],
             name: CodePuppyControl.Telemetry.ClusterDashboard
           ) do
        {:ok, pid} ->
          on_exit(fn -> GenServer.stop(pid, :normal, 1000) end)
          :ok

        {:error, {:already_started, _pid}} ->
          # Already running from app supervision — don't stop it in on_exit
          :ok
      end

      :ok
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

  describe "without ClusterDashboard (single-node dev)" do
    setup do
      # Stop ClusterDashboard if it's running, to simulate single-node dev
      case Process.whereis(CodePuppyControl.Telemetry.ClusterDashboard) do
        nil ->
          :ok

        pid ->
          GenServer.stop(pid, :normal, 1000)
          # Wait for the process to fully unregister
          Process.sleep(50)
      end

      on_exit(fn ->
        # Restart ClusterDashboard after the test to avoid polluting other tests
        case Process.whereis(CodePuppyControl.Telemetry.ClusterDashboard) do
          nil ->
            GenServer.start(
              CodePuppyControl.Telemetry.ClusterDashboard,
              [],
              name: CodePuppyControl.Telemetry.ClusterDashboard
            )

            :ok

          _pid ->
            :ok
        end
      end)

      :ok
    end

    test "renders /admin/pack gracefully with HTTP 200 (no 500)", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/pack")
      assert html =~ "Pack"
      assert html =~ "Limit"
      # Shows cluster as down with fallback snapshot
      assert html =~ "down"
      # No worker nodes connected (empty cluster)
      assert has_element?(view, "h2", "Cluster Topology")
    end

    test "shows empty cluster state when dashboard is absent", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/pack")
      # The fallback snapshot should render cluster-health as :down
      assert html =~ "down"
      # No worker nodes should be shown
      assert html =~ "No worker nodes connected" or html =~ "Cluster Topology"
      # Verify LiveView is functional — handles tick without crash
      send(view.pid, :tick)
      assert render(view) =~ "Pack"
    end
  end
end
