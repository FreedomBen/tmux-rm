defmodule TermigateWeb.AuthController do
  use TermigateWeb, :controller

  alias Termigate.Auth

  require Logger

  @doc "POST /api/login — returns bearer token on success."
  def login(conn, %{"username" => username, "password" => password}) do
    case Auth.verify_credentials(username, password) do
      :ok ->
        Logger.info("Login success: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:termigate, :auth, :login, :success],
          %{},
          %{username: username, ip: format_ip(conn)}
        )

        max_age = Termigate.Auth.session_ttl_seconds()
        token = Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{username: username})

        json(conn, %{token: token, expires_in: max_age})

      :error ->
        Logger.info("Login failure: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:termigate, :auth, :login, :failure],
          %{},
          %{username: username, ip: format_ip(conn)}
        )

        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})
    end
  end

  @doc "POST /login — web form login, sets session cookie."
  def web_login(conn, %{"username" => username, "password" => password}) do
    case Auth.verify_credentials(username, password) do
      :ok ->
        Logger.info("Web login success: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:termigate, :auth, :login, :success],
          %{},
          %{username: username, ip: format_ip(conn)}
        )

        conn
        |> put_session("authenticated_at", System.system_time(:second))
        |> redirect(to: "/")

      :error ->
        Logger.info("Web login failure: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:termigate, :auth, :login, :failure],
          %{},
          %{username: username, ip: format_ip(conn)}
        )

        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: "/login")
    end
  end

  @doc "DELETE /logout — clears session, redirects to login."
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
        Logger.info("Post-setup auto-login: #{username} from #{format_ip(conn)}")

        conn
        |> put_session("authenticated_at", System.system_time(:second))
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
end
