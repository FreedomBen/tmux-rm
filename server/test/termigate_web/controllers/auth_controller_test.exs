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

    # Regression: TERMIGATE_SECURE_COOKIES is not set at test compile time,
    # so the endpoint's @session_options compiles with `secure: false`. The
    # session cookie must therefore be emitted without the Secure attribute,
    # otherwise plain-HTTP loopback / LAN / 10.0.2.2 emulator workflows would
    # silently lose the cookie on every request and login would never stick.
    test "emits a Set-Cookie without Secure under default config (HTTP login keeps working)",
         %{conn: conn} do
      original = Application.get_env(:termigate, :auth_token)

      try do
        Application.put_env(:termigate, :auth_token, "test-secret-token")

        conn =
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "test-secret-token"})

        assert redirected_to(conn) == "/"

        session_cookie =
          conn
          |> get_resp_header("set-cookie")
          |> Enum.find(&String.starts_with?(&1, "_termigate_key="))

        assert session_cookie,
               "expected a Set-Cookie line for _termigate_key, got: " <>
                 inspect(get_resp_header(conn, "set-cookie"))

        attributes =
          session_cookie
          |> String.split(";")
          |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

        refute "secure" in attributes,
               "expected default session cookie to omit Secure, got: #{inspect(session_cookie)}"

        # Sanity-check the other hardening attributes that Plug.Session sets so
        # this test fails loudly if a later refactor strips them by accident.
        assert "httponly" in attributes
        assert "samesite=lax" in attributes
      after
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
      end
    end
  end

  describe "POST /login (web) — rate limit" do
    test "redirects to /login with flash after exceeding the per-IP limit", %{conn: conn} do
      original = Application.get_env(:termigate, :auth_token)

      try do
        Application.put_env(:termigate, :auth_token, "test-secret-token")

        # Burn the 5-attempts-per-60s budget for this IP.
        for _ <- 1..5 do
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "wrong"})
        end

        rate_limited =
          conn
          |> init_test_session(%{})
          |> post("/login", %{username: "admin", password: "wrong"})

        assert redirected_to(rate_limited) == "/login"
        assert Phoenix.Flash.get(rate_limited.assigns.flash, :error) =~ "Too many login attempts"
        assert [retry_after] = get_resp_header(rate_limited, "retry-after")
        assert String.to_integer(retry_after) >= 0
      after
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
      end
    end
  end

  describe "POST /api/login — rate limit" do
    test "returns 429 JSON after exceeding the per-IP limit", %{conn: conn} do
      for _ <- 1..5 do
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/login", %{username: "admin", password: "wrong"})
      end

      rate_limited =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/login", %{username: "admin", password: "wrong"})

      body = json_response(rate_limited, 429)
      assert body["error"] == "rate_limited"
      assert is_integer(body["retry_after"])
      assert [_retry_after] = get_resp_header(rate_limited, "retry-after")
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

  describe "GET /logout" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"authenticated_at" => System.system_time(:second)})
        |> get("/logout")

      assert redirected_to(conn) == "/login"
      refute get_session(conn, "authenticated_at")
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
