defmodule CodePuppyControlWeb.Admin.SessionsLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  test "renders the sessions page chrome", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/sessions")
    assert html =~ "Sessions"
    # The sidebar shows Sessions as active.
    assert has_element?(view, "a.active", "Sessions")
  end

  test "renders either a populated table or an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/sessions")
    # In the test env, there may or may not be sessions depending on test isolation.
    # Either way is valid.
    assert html =~ "sessions persisted in SQLite" or html =~ "Name"
  end

  test "ignores random PubSub messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/sessions")
    send(view.pid, {:event, %{type: "tool_result"}})
    assert render(view) =~ "Sessions"
  end
end
