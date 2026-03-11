defmodule TmuxRmWeb.AuthControllerTest do
  use TmuxRmWeb.ConnCase, async: false

  describe "POST /api/login" do
    test "returns 401 with invalid credentials", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/login", %{username: "admin", password: "wrong"})

      assert json_response(conn, 401)["error"] == "invalid_credentials"
    end

    test "returns token with valid auth_token credentials", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.put_env(:tmux_rm, :auth_token, "test-secret-token")

        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> post("/api/login", %{username: "admin", password: "test-secret-token"})

        body = json_response(conn, 200)
        assert is_binary(body["token"])
        assert is_integer(body["expires_in"])
      after
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end
    end
  end

  describe "POST /login (web)" do
    test "redirects to / on success", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.put_env(:tmux_rm, :auth_token, "test-secret-token")

        conn =
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "test-secret-token"})

        assert redirected_to(conn) == "/"
      after
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end
    end

    test "redirects to /login on failure", %{conn: conn} do
      original = Application.get_env(:tmux_rm, :auth_token)

      try do
        Application.put_env(:tmux_rm, :auth_token, "test-secret-token")

        conn =
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "wrong"})

        assert redirected_to(conn) == "/login"
      after
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end
    end
  end

  describe "DELETE /logout" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"authenticated_at" => System.system_time(:second)})
        |> delete("/logout")

      assert redirected_to(conn) == "/login"
    end
  end
end
