defmodule TmuxRmWeb.MetricsControllerTest do
  use TmuxRmWeb.ConnCase, async: false

  describe "GET /metrics" do
    test "returns JSON with metrics data", %{conn: conn} do
      conn = get(conn, "/metrics")
      body = json_response(conn, 200)
      assert is_integer(body["active_pane_streams"])
      assert is_integer(body["uptime_seconds"])
      assert is_map(body["vm"])
      assert is_number(body["vm"]["memory_total_mb"])
      assert is_integer(body["vm"]["process_count"])
    end

    test "returns 401 when metrics_token is set and no auth header", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :metrics_token)

      try do
        Application.put_env(:tmux_rm, :metrics_token, "secret-metrics-token")
        conn = get(conn, "/metrics")
        assert json_response(conn, 401)["error"] == "unauthorized"
      after
        if original,
          do: Application.put_env(:tmux_rm, :metrics_token, original),
          else: Application.delete_env(:tmux_rm, :metrics_token)
      end
    end

    test "returns metrics when correct token provided", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :metrics_token)

      try do
        Application.put_env(:tmux_rm, :metrics_token, "secret-metrics-token")

        conn =
          conn
          |> put_req_header("authorization", "Bearer secret-metrics-token")
          |> get("/metrics")

        body = json_response(conn, 200)
        assert is_integer(body["active_pane_streams"])
      after
        if original,
          do: Application.put_env(:tmux_rm, :metrics_token, original),
          else: Application.delete_env(:tmux_rm, :metrics_token)
      end
    end
  end
end
