defmodule TermigateWeb.MCPEndpointTest do
  use TermigateWeb.ConnCase

  describe "POST /mcp" do
    @tag :skip_auth
    test "rejects unauthenticated requests", %{conn: conn} do
      # Enable auth
      Application.put_env(:termigate, :auth_token, "real-token")

      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end
end
