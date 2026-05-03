defmodule TermigateWeb.ConfigControllerTest do
  use TermigateWeb.ConnCase, async: false

  alias Termigate.Config

  describe "GET /api/config" do
    test "returns config as JSON", %{conn: conn} do
      conn = get(conn, "/api/config")
      body = json_response(conn, 200)
      assert is_map(body)
      assert Map.has_key?(body, "quick_actions")
    end

    test "strips auth.password_hash from the response", %{conn: conn} do
      hash = Termigate.Auth.hash_password("super-secret")

      {:ok, _} =
        Config.update(fn cfg ->
          Map.put(cfg, "auth", %{
            "username" => "admin",
            "password_hash" => hash,
            "session_ttl_hours" => 12
          })
        end)

      on_exit(fn ->
        if GenServer.whereis(Config) do
          Config.update(fn cfg -> Map.delete(cfg, "auth") end)
        end
      end)

      # Writing the auth section bumps Auth.auth_version, so the bearer minted
      # in ConnCase is now stale. Re-mint against the current version.
      fresh_token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{
          auth_version: Termigate.Auth.auth_version()
        })

      conn = put_req_header(conn, "authorization", "Bearer #{fresh_token}")

      body = conn |> get("/api/config") |> json_response(200)

      assert body["auth"]["username"] == "admin"
      assert body["auth"]["session_ttl_hours"] == 12
      refute Map.has_key?(body["auth"], "password_hash")
      refute body |> Jason.encode!() |> String.contains?(hash)
    end
  end
end
