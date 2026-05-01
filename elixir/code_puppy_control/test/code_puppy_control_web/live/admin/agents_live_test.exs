defmodule CodePuppyControlWeb.Admin.AgentsLiveTest do
  use CodePuppyControlWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:code_puppy_control, :admin_ui, [])
    Application.put_env(:code_puppy_control, :admin_ui, allowed_ips: :loopback)
    on_exit(fn -> Application.put_env(:code_puppy_control, :admin_ui, original) end)
    {:ok, conn: build_conn()}
  end

  test "renders the agents page chrome", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/agents")
    assert html =~ "Agents"
    # The sidebar shows Agents as active.
    assert has_element?(view, "a.active", "Agents")
  end

  test "renders either a populated table or an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/agents")
    # In the test env, AgentCatalogue may or may not have populated agents
    # depending on test isolation. Either way is valid.
    assert html =~ "agents discovered" or html =~ "Display"
  end

  test "ignores random PubSub messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/agents")
    send(view.pid, {:event, %{type: "tool_result"}})
    assert render(view) =~ "Agents"
  end
end
