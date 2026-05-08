defmodule CodePuppyControlWeb.Admin.WorktreesLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  test "renders chrome and either a table or empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/worktrees")
    assert html =~ "Worktrees"
    # Either real worktrees from the project, or the empty fallback.
    assert html =~ "Path" or html =~ "No worktrees discovered"
    assert has_element?(view, "a.active", "Worktrees")
  end

  test "refresh button re-runs the worktree query", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/worktrees")
    html = render_click(view, "refresh")
    assert html =~ "Worktrees"
  end
end
