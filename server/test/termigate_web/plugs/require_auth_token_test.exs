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

      token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{
          username: "admin",
          auth_version: "anything"
        })

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

      token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{
          username: "admin",
          auth_version: Termigate.Auth.auth_version()
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      refute conn.halted
    end

    test "returns 401 when token lacks auth_version claim (pre-fix token)" do
      Application.put_env(:termigate, :auth_token, "some-token")
      legacy_token = Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{username: "admin"})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{legacy_token}")
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 when auth_token rotates after the bearer was issued" do
      Application.put_env(:termigate, :auth_token, "first-token")

      token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{
          username: "admin",
          auth_version: Termigate.Auth.auth_version()
        })

      # Rotate the env-var token: auth_version derived from it now changes.
      Application.put_env(:termigate, :auth_token, "second-token")

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequireAuthToken.call(RequireAuthToken.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end
end
