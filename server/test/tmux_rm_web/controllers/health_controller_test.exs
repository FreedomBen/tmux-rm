defmodule TmuxRmWeb.HealthControllerTest do
  use TmuxRmWeb.ConnCase, async: false

  describe "GET /healthz" do
    test "returns 200 with JSON body", %{conn: conn} do
      conn = get(conn, "/healthz")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert Map.has_key?(body, "tmux")
    end

    test "body contains tmux key with known value", %{conn: conn} do
      conn = get(conn, "/healthz")
      body = json_response(conn, 200)
      assert body["tmux"] in ["ok", "no_server"]
    end
  end
end
