defmodule TermigateWeb.AuthControllerTest do
  use TermigateWeb.ConnCase, async: false

  describe "POST /api/login" do
    test "returns 401 with invalid credentials", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/login", %{username: "admin", password: "wrong"})

      assert json_response(conn, 401)["error"] == "invalid_credentials"
    end

    test "returns token with valid auth_token credentials", %{conn: conn} do
      original = Application.get_env(:termigate, :auth_token)

      try do
        Application.put_env(:termigate, :auth_token, "test-secret-token")

        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> post("/api/login", %{username: "admin", password: "test-secret-token"})

        body = json_response(conn, 200)
        assert is_binary(body["token"])
        assert is_integer(body["expires_in"])
      after
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
      end
    end
  end

  describe "POST /login (web)" do
    test "redirects to / on success", %{conn: conn} do
      original = Application.get_env(:termigate, :auth_token)

      try do
        Application.put_env(:termigate, :auth_token, "test-secret-token")

        conn =
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "test-secret-token"})

        assert redirected_to(conn) == "/"
      after
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
      end
    end

    test "redirects to /login on failure", %{conn: conn} do
      original = Application.get_env(:termigate, :auth_token)

      try do
        Application.put_env(:termigate, :auth_token, "test-secret-token")

        conn =
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "wrong"})

        assert redirected_to(conn) == "/login"
      after
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
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

  describe "GET /post-setup" do
    @describetag :skip_auth

    test "with a valid token, sets session and redirects to /", %{conn: conn} do
      token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "post_setup", %{username: "admin"})

      conn = get(conn, "/post-setup", %{"token" => token})

      assert redirected_to(conn) == "/"
      assert get_session(conn, "authenticated_at")
    end

    test "with an invalid token, redirects to /login with flash error", %{conn: conn} do
      conn = get(conn, "/post-setup", %{"token" => "not-a-real-token"})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, "authenticated_at")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Setup link expired"
    end

    test "without a token, redirects to /login", %{conn: conn} do
      conn = get(conn, "/post-setup")

      assert redirected_to(conn) == "/login"
    end
  end
end
