defmodule TermigateWeb.AuthController do
  use TermigateWeb, :controller

  alias Termigate.Auth

  require Logger

  @doc "POST /api/login — returns bearer token on success."
  def login(conn, %{"username" => username, "password" => password}) do
    safe_user = sanitize_user(username)
    ip = format_ip(conn)

    case Auth.verify_credentials(username, password) do
      :ok ->
        # Static token logins are username-agnostic — log a fixed sentinel
        # so an attacker who guesses the token cannot forge arbitrary
        # usernames into the audit trail.
        log_user = if Auth.token_login?(password), do: "<token>", else: safe_user
        Logger.info("Login success: #{log_user} from #{ip}")

        :telemetry.execute(
          [:termigate, :auth, :login, :success],
          %{},
          %{username: log_user, ip: ip}
        )

        max_age = Termigate.Auth.session_ttl_seconds()

        token =
          Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{
            username: username,
            auth_version: Auth.auth_version()
          })

        json(conn, %{token: token, expires_in: max_age})

      :error ->
        Logger.info("Login failure: #{safe_user} from #{ip}")

        :telemetry.execute(
          [:termigate, :auth, :login, :failure],
          %{},
          %{username: safe_user, ip: ip}
        )

        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})
    end
  end

  @doc "POST /login — web form login, sets session cookie."
  def web_login(conn, %{"username" => username, "password" => password}) do
    safe_user = sanitize_user(username)
    ip = format_ip(conn)

    case Auth.verify_credentials(username, password) do
      :ok ->
        log_user = if Auth.token_login?(password), do: "<token>", else: safe_user
        Logger.info("Web login success: #{log_user} from #{ip}")

        :telemetry.execute(
          [:termigate, :auth, :login, :success],
          %{},
          %{username: log_user, ip: ip}
        )

        conn
        |> put_session("authenticated_at", System.system_time(:second))
        |> put_session("auth_version", Auth.auth_version())
        |> redirect(to: "/")

      :error ->
        Logger.info("Web login failure: #{safe_user} from #{ip}")

        :telemetry.execute(
          [:termigate, :auth, :login, :failure],
          %{},
          %{username: safe_user, ip: ip}
        )

        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: "/login")
    end
  end

  @doc "DELETE/GET /logout — clears session, redirects to login."
  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end

  @doc """
  GET /post-setup — verifies a one-time setup token and signs the user in.
  Used by SetupLive to hand off to a regular HTTP request that can set the
  session cookie, so the user does not have to retype their credentials right
  after creating the account.
  """
  def post_setup(conn, %{"token" => token}) do
    case Phoenix.Token.verify(TermigateWeb.Endpoint, "post_setup", token, max_age: 60) do
      {:ok, %{username: username}} ->
        Logger.info("Post-setup auto-login: #{sanitize_user(username)} from #{format_ip(conn)}")

        conn
        |> put_session("authenticated_at", System.system_time(:second))
        |> put_session("auth_version", Auth.auth_version())
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Setup link expired. Please log in.")
        |> redirect(to: "/login")
    end
  end

  def post_setup(conn, _params) do
    redirect(conn, to: "/login")
  end

  defp format_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # Strips control characters (CR/LF/escapes) so user-supplied usernames cannot
  # forge log lines or pollute terminal-based log viewers, and caps length so a
  # huge value cannot blow up sinks.
  defp sanitize_user(nil), do: "<missing>"

  defp sanitize_user(s) when is_binary(s),
    do: s |> String.replace(~r/[\x00-\x1f\x7f]/, "?") |> String.slice(0, 64)

  defp sanitize_user(other), do: other |> to_string() |> sanitize_user()
end
