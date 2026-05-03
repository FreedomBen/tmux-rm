defmodule TermigateWeb.Plugs.RequireAuthTest do
  use TermigateWeb.ConnCase, async: false

  alias TermigateWeb.Plugs.RequireAuth

  # This test manages auth_token directly — skip ConnCase auto-setup
  @moduletag :skip_auth

  describe "call/2" do
    test "redirects to /setup when auth is not enabled", %{conn: conn} do
      Application.delete_env(:termigate, :auth_token)

      conn =
        conn
        |> init_test_session(%{})
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert redirected_to(conn) == "/setup"
    end

    test "redirects to /login when no session and auth enabled", %{conn: conn} do
      Application.put_env(:termigate, :auth_token, "some-token")

      conn =
        conn
        |> init_test_session(%{})
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert redirected_to(conn) == "/login"
    end

    test "passes through when session has authenticated_at and current auth_version",
         %{conn: conn} do
      Application.put_env(:termigate, :auth_token, "some-token")

      conn =
        conn
        |> init_test_session(%{
          "authenticated_at" => System.system_time(:second),
          "auth_version" => Termigate.Auth.auth_version()
        })
        |> RequireAuth.call(RequireAuth.init([]))

      refute conn.halted
    end

    test "redirects to /login when session lacks auth_version (pre-fix cookie)",
         %{conn: conn} do
      Application.put_env(:termigate, :auth_token, "some-token")

      conn =
        conn
        |> init_test_session(%{"authenticated_at" => System.system_time(:second)})
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert redirected_to(conn) == "/login"
    end

    test "clears session and redirects when auth_version no longer matches",
         %{conn: conn} do
      Application.put_env(:termigate, :auth_token, "first-token")
      stale_version = Termigate.Auth.auth_version()

      # Rotate the static token — Auth.auth_version now differs.
      Application.put_env(:termigate, :auth_token, "second-token")
      refute Termigate.Auth.auth_version() == stale_version

      conn =
        conn
        |> init_test_session(%{
          "authenticated_at" => System.system_time(:second),
          "auth_version" => stale_version
        })
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert redirected_to(conn) == "/login"
      refute get_session(conn, "authenticated_at")
      refute get_session(conn, "auth_version")
    end
  end
end
