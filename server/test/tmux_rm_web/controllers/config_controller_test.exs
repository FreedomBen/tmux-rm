defmodule TmuxRmWeb.ConfigControllerTest do
  use TmuxRmWeb.ConnCase, async: false

  describe "GET /api/config" do
    test "returns config as JSON", %{conn: conn} do
      conn = get(conn, "/api/config")
      body = json_response(conn, 200)
      assert is_map(body)
      assert Map.has_key?(body, "quick_actions")
    end
  end
end
