defmodule CodePuppyControlWeb.AgentsControllerTest do
  use CodePuppyControlWeb.ConnCase, async: true

  # ── GET /api/agents ─────────────────────────────────────────────────────

  describe "GET /api/agents" do
    test "returns a list of agents" do
      conn =
        build_conn()
        |> get("/api/agents")

      body = json_response(conn, 200)
      assert is_list(body)
    end

    test "each agent has name, display_name, and description" do
      conn =
        build_conn()
        |> get("/api/agents")

      body = json_response(conn, 200)

      for agent <- body do
        assert Map.has_key?(agent, "name")
        assert Map.has_key?(agent, "display_name")
        assert Map.has_key?(agent, "description")
      end
    end
  end
end
