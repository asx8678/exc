defmodule CodePuppyControlWeb.Admin.JobsLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  test "renders the jobs page chrome and filter form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/jobs")
    assert html =~ "Jobs"
    assert html =~ "Status:"
    assert has_element?(view, "select[name=status]")
  end

  test "shows the empty state when there are no jobs", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/jobs")
    assert html =~ "No jobs match the current filter."
  end

  test "filter event handler accepts status changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/jobs")

    # Pick a status that exists as an atom — :running is loaded by Run.State.
    html = render_change(view, "filter", %{"status" => "running"})
    assert html =~ "Jobs"

    # And reset
    html = render_change(view, "filter", %{"status" => "all"})
    assert html =~ "Jobs"
  end

  test "filter falls back to :all on garbage input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/jobs")
    html = render_change(view, "filter", %{"status" => "this-is-not-a-status-atom-xyz"})
    assert html =~ "Jobs"
  end

  test "handle_info({:event, _}) is non-crashing for unknown run_ids", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/jobs")
    send(view.pid, {:event, %{type: "status", run_id: "no-such-run", status: "running"}})
    send(view.pid, {:event, %{type: "completed", run_id: "no-such-run-2"}})
    send(view.pid, {:event, %{type: "noise"}})
    assert render(view) =~ "Jobs"
  end
end
