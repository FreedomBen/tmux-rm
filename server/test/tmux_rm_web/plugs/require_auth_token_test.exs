defmodule TmuxRmWeb.Plugs.RequireAuthTokenTest do
  use TmuxRmWeb.ConnCase, async: false

  alias TmuxRmWeb.Plugs.RequireAuthToken

  describe "call/2" do
    test "passes through when auth is not enabled", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.delete_env(:tmux_rm, :auth_token)

        conn = RequireAuthToken.call(conn, RequireAuthToken.init([]))
        refute conn.halted
      after
        if original, do: Application.put_env(:tmux_rm, :auth_token, original)
      end
    end

    test "returns 401 when no Authorization header and auth enabled", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.put_env(:tmux_rm, :auth_token, "some-token")

        conn = RequireAuthToken.call(conn, RequireAuthToken.init([]))
        assert conn.halted
        assert conn.status == 401
      after
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end
    end

    test "returns 401 with invalid token", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.put_env(:tmux_rm, :auth_token, "some-token")

        conn =
          conn
          |> put_req_header("authorization", "Bearer invalid-token")
          |> RequireAuthToken.call(RequireAuthToken.init([]))

        assert conn.halted
        assert conn.status == 401
      after
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end
    end

    test "passes through with valid token", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.put_env(:tmux_rm, :auth_token, "some-token")
        token = Phoenix.Token.sign(TmuxRmWeb.Endpoint, "api_token", %{username: "admin"})

        conn =
          conn
          |> put_req_header("authorization", "Bearer #{token}")
          |> RequireAuthToken.call(RequireAuthToken.init([]))

        refute conn.halted
      after
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end
    end
  end
end
