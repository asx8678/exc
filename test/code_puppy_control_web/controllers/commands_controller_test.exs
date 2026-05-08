defmodule CodePuppyControlWeb.CommandsControllerTest do
  use CodePuppyControlWeb.ConnCase, async: true

  # ── GET /api/commands ───────────────────────────────────────────────────

  describe "GET /api/commands" do
    test "returns a list (may include agents from AgentCatalogue)" do
      conn =
        build_conn()
        |> get("/api/commands")

      body = json_response(conn, 200)
      assert is_list(body)
    end
  end

  # ── GET /api/commands/:name ─────────────────────────────────────────────

  describe "GET /api/commands/:name" do
    test "returns command info for a known command" do
      conn =
        build_conn()
        |> get("/api/commands/help")

      body = json_response(conn, 200)
      assert body["name"] == "help"
      assert is_binary(body["description"])
    end

    test "returns 404 for unknown command" do
      conn =
        build_conn()
        |> get("/api/commands/zzz_nonexistent")

      body = json_response(conn, 404)
      assert body["error"] =~ "not found"
    end
  end

  # ── POST /api/commands/execute ──────────────────────────────────────────

  describe "POST /api/commands/execute" do
    test "returns 501 Not Implemented (stub)" do
      conn =
        build_conn()
        |> post_json("/api/commands/execute", %{command: "/help"})

      body = json_response(conn, 501)
      assert body["error"] =~ "not yet implemented"
    end
  end

  # ── POST /api/commands/autocomplete ─────────────────────────────────────

  describe "POST /api/commands/autocomplete" do
    test "returns matching suggestions for a partial command" do
      conn =
        build_conn()
        |> post_json("/api/commands/autocomplete", %{partial: "/h"})

      body = json_response(conn, 200)
      assert is_list(body["suggestions"])
      names = Enum.map(body["suggestions"], & &1["name"])
      assert "help" in names
    end

    test "returns empty suggestions for non-matching partial" do
      conn =
        build_conn()
        |> post_json("/api/commands/autocomplete", %{partial: "/zzz"})

      body = json_response(conn, 200)
      assert body["suggestions"] == []
    end
  end
end
