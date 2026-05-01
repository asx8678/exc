defmodule CodePuppyControlWeb.ConfigControllerTest do
  use CodePuppyControlWeb.ConnCase, async: true

  # ── GET /api/config ─────────────────────────────────────────────────────

  describe "GET /api/config" do
    test "returns config map with keys and values" do
      conn =
        build_conn()
        |> get("/api/config")

      body = json_response(conn, 200)
      assert is_map(body["config"])
    end

    test "redacts sensitive keys" do
      conn =
        build_conn()
        |> get("/api/config")

      body = json_response(conn, 200)
      config = body["config"]

      # Any key matching sensitive patterns should be redacted
      for key <- Map.keys(config) do
        if key =~ ~r/(api_key|token|secret|password|credential|auth_key|private_key)/i do
          assert config[key] == "********",
                 "Expected key '#{key}' to be redacted, got: #{inspect(config[key])}"
        end
      end
    end
  end

  # ── GET /api/config/keys ────────────────────────────────────────────────

  describe "GET /api/config/keys" do
    test "returns a list of valid config keys" do
      conn =
        build_conn()
        |> get("/api/config/keys")

      body = json_response(conn, 200)
      assert is_list(body)
    end
  end

  # ── GET /api/config/:key ────────────────────────────────────────────────

  describe "GET /api/config/:key" do
    test "returns 404 for unknown key" do
      conn =
        build_conn()
        |> get("/api/config/nonexistent_key_xyz")

      body = json_response(conn, 404)
      assert body["error"] =~ "not found"
    end

    test "returns key and value for known key" do
      # First get the list of valid keys
      conn = build_conn() |> get("/api/config/keys")
      keys = json_response(conn, 200)

      if length(keys) > 0 do
        key = hd(keys)

        conn =
          build_conn()
          |> get("/api/config/#{key}")

        body = json_response(conn, 200)
        assert body["key"] == key
        assert Map.has_key?(body, "value")
      end
    end
  end

  # ── PUT /api/config/:key ────────────────────────────────────────────────

  describe "PUT /api/config/:key" do
    test "returns 404 for unknown key" do
      conn =
        build_conn()
        |> put_json("/api/config/nonexistent_key_xyz", %{value: "test"})

      body = json_response(conn, 404)
      assert body["error"] =~ "not found"
    end

    test "returns 400 when value is missing" do
      conn =
        build_conn()
        |> put_json("/api/config/model", %{})

      body = json_response(conn, 400)
      assert body["error"] =~ "Missing required field: value"
    end

    test "returns 422 when value is a map (complex type)" do
      conn =
        build_conn()
        |> put_json("/api/config/some_key", %{value: %{nested: true}})

      body = json_response(conn, 422)
      assert body["error"] =~ "must be a string, number, boolean, or null"
      assert body["received_type"] == "map"
    end

    test "returns 422 when value is a list (complex type)" do
      conn =
        build_conn()
        |> put_json("/api/config/some_key", %{value: [1, 2, 3]})

      body = json_response(conn, 422)
      assert body["error"] =~ "must be a string, number, boolean, or null"
      assert body["received_type"] == "list"
    end
  end

  # ── DELETE /api/config/:key ─────────────────────────────────────────────

  describe "DELETE /api/config/:key" do
    test "returns 404 for unknown key" do
      conn =
        build_conn()
        |> delete("/api/config/nonexistent_key_xyz")

      body = json_response(conn, 404)
      assert body["error"] =~ "not found"
    end
  end
end
