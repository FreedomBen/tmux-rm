defmodule TermigateWeb.MetricsControllerTest do
  use TermigateWeb.ConnCase, async: false

  setup do
    original_token = Application.get_env(:termigate, :metrics_token)
    original_public = Application.get_env(:termigate, :public_metrics)

    on_exit(fn ->
      if original_token,
        do: Application.put_env(:termigate, :metrics_token, original_token),
        else: Application.delete_env(:termigate, :metrics_token)

      if original_public,
        do: Application.put_env(:termigate, :public_metrics, original_public),
        else: Application.delete_env(:termigate, :public_metrics)
    end)

    :ok
  end

  defp from_remote(conn), do: %{conn | remote_ip: {203, 0, 113, 7}}

  describe "GET /metrics — payload" do
    test "returns generic VM/uptime fields and omits reconnaissance fields", %{conn: conn} do
      body = conn |> get("/metrics") |> json_response(200)

      assert is_integer(body["uptime_seconds"])
      assert is_map(body["vm"])
      assert is_number(body["vm"]["memory_total_mb"])
      assert is_integer(body["vm"]["process_count"])

      refute Map.has_key?(body, "auth_mode")
      refute Map.has_key?(body, "active_pane_streams")
    end
  end

  describe "GET /metrics — access control without a token" do
    test "loopback peer is allowed", %{conn: conn} do
      assert %{"uptime_seconds" => _} = conn |> get("/metrics") |> json_response(200)
    end

    test "remote peer gets 404 by default (route existence is hidden)", %{conn: conn} do
      assert json_response(from_remote(conn) |> get("/metrics"), 404)["error"] == "not_found"
    end

    test "remote peer is allowed when TERMIGATE_PUBLIC_METRICS is enabled", %{conn: conn} do
      Application.put_env(:termigate, :public_metrics, true)

      assert %{"uptime_seconds" => _} =
               conn |> from_remote() |> get("/metrics") |> json_response(200)
    end
  end

  describe "GET /metrics — access control with a token" do
    setup do
      Application.put_env(:termigate, :metrics_token, "secret-metrics-token")
      :ok
    end

    test "loopback still served without a token (token is for remote scrapers)", %{conn: conn} do
      assert %{"uptime_seconds" => _} = conn |> get("/metrics") |> json_response(200)
    end

    test "remote peer with no header gets 401", %{conn: conn} do
      assert json_response(from_remote(conn) |> get("/metrics"), 401)["error"] == "unauthorized"
    end

    test "remote peer with valid bearer token is served", %{conn: conn} do
      conn =
        conn
        |> from_remote()
        |> put_req_header("authorization", "Bearer secret-metrics-token")
        |> get("/metrics")

      assert %{"uptime_seconds" => _} = json_response(conn, 200)
    end

    test "remote peer with wrong token gets 401", %{conn: conn} do
      conn =
        conn
        |> from_remote()
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get("/metrics")

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "remote peer with same-prefix longer token gets 401", %{conn: conn} do
      conn =
        conn
        |> from_remote()
        |> put_req_header("authorization", "Bearer secret-metrics-token-extra")
        |> get("/metrics")

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end
end
