defmodule TmuxRmWeb.AuthController do
  use TmuxRmWeb, :controller

  alias TmuxRm.Auth

  require Logger

  @doc "POST /api/login — returns bearer token on success."
  def login(conn, %{"username" => username, "password" => password}) do
    case Auth.verify_credentials(username, password) do
      :ok ->
        Logger.info("Login success: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:tmux_rm, :auth, :login, :success],
          %{},
          %{username: username, ip: format_ip(conn)}
        )

        max_age = Application.get_env(:tmux_rm, :auth_token_max_age, 604_800)
        token = Phoenix.Token.sign(TmuxRmWeb.Endpoint, "api_token", %{username: username})

        json(conn, %{token: token, expires_in: max_age})

      :error ->
        Logger.info("Login failure: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:tmux_rm, :auth, :login, :failure],
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
          [:tmux_rm, :auth, :login, :success],
          %{},
          %{username: username, ip: format_ip(conn)}
        )

        conn
        |> put_session("authenticated_at", System.system_time(:second))
        |> redirect(to: "/")

      :error ->
        Logger.info("Web login failure: #{username} from #{format_ip(conn)}")

        :telemetry.execute(
          [:tmux_rm, :auth, :login, :failure],
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

  defp format_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
