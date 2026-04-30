defmodule TermigateWeb.Plugs.RateLimit do
  @moduledoc "Rate limiting plug. Configure per-route: `plug RateLimit, key: :login`."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, put_flash: 3, redirect: 2, get_format: 1]

  require Logger

  @default_limits %{
    login: {5, 60},
    session_create: {10, 60},
    websocket: {10, 60}
  }

  def init(opts), do: opts

  def call(conn, opts) do
    key = Keyword.fetch!(opts, :key)
    limits = Application.get_env(:termigate, :rate_limits, @default_limits)
    {max_requests, window} = Map.get(limits, key, {10, 60})

    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case TermigateWeb.RateLimitStore.check(ip, key, {max_requests, window}) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after} ->
        Logger.warning("Rate limit exceeded: #{ip} on #{key}")
        rate_limited_response(conn, retry_after)
    end
  end

  defp rate_limited_response(conn, retry_after) do
    conn = put_resp_header(conn, "retry-after", to_string(retry_after))

    case get_format(conn) do
      "html" ->
        conn
        |> put_flash(
          :error,
          "Too many login attempts. Please wait #{retry_after} seconds and try again."
        )
        |> redirect(to: "/login")
        |> halt()

      _ ->
        conn
        |> put_status(429)
        |> json(%{error: "rate_limited", retry_after: retry_after})
        |> halt()
    end
  end
end
