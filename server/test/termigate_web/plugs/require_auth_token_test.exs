defmodule TermigateWeb.Plugs.RequireAuthTokenTest do
  use TermigateWeb.ConnCase, async: false

  alias TermigateWeb.Plugs.RequireAuthToken

  # This test manages auth_token directly
  @moduletag :skip_auth

  describe "call/2" do
    test "fails closed with 503 setup_required when auth is not configured" do
      Application.delete_env(:termigate, :auth_token)

      conn =
        Phoenix.ConnTest.build_conn()
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      assert conn.halted
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "setup_required"}
    end

    test "fails closed even with a Bearer token before setup completes" do
      Application.delete_env(:termigate, :auth_token)
      token = Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{username: "admin"})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      assert conn.halted
      assert conn.status == 503
    end

    test "returns 401 when no Authorization header and auth enabled" do
      Application.put_env(:termigate, :auth_token, "some-token")

      conn =
        Phoenix.ConnTest.build_conn()
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 with invalid token" do
      Application.put_env(:termigate, :auth_token, "some-token")

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer invalid-token")
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "passes through with valid token" do
      Application.put_env(:termigate, :auth_token, "some-token")
      token = Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{username: "admin"})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      refute conn.halted
    end
  end
end
