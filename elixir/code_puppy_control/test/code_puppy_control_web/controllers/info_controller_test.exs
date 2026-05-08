defmodule CodePuppyControlWeb.InfoControllerTest do
  use CodePuppyControlWeb.ConnCase, async: true

  test "GET / returns app info JSON" do
    conn =
      build_conn()
      |> get("/")

    body = json_response(conn, 200)

    assert body["app"] == "code_puppy_control"
    assert body["status"] == "ok"
    assert is_binary(body["version"])
    assert is_map(body["endpoints"])
    assert body["endpoints"]["health"] == "/health"
    assert body["endpoints"]["api"] == "/api"
    assert body["endpoints"]["websocket"] == "/socket"
  end
end
