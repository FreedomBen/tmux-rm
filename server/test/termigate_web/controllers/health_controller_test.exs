defmodule TermigateWeb.HealthControllerTest do
  use TermigateWeb.ConnCase, async: true

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

    # Regression: anyone reachable on the network can hit /healthz, so the
    # response body must not advertise auth mode, VM stats, or pane counts.
    # Detailed metrics live behind the metrics_token gate on /metrics.
    test "does not disclose auth_mode, vm memory, or stream counts", %{conn: conn} do
      conn = get(conn, "/healthz")
      body = json_response(conn, 200)
      refute Map.has_key?(body, "auth_mode")
      refute Map.has_key?(body, "vm_memory_mb")
      refute Map.has_key?(body, "active_pane_streams")
      assert Map.keys(body) |> Enum.sort() == ["status", "tmux"]
    end
  end
end
