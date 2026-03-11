defmodule TmuxRmWeb.Plugs.RateLimit do
  @moduledoc "Rate limiting plug. Configure per-route: `plug RateLimit, key: :login`."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  @default_limits %{
    login: {5, 60},
    session_create: {10, 60},
    websocket: {10, 60}
  }

  def init(opts), do: opts

  def call(conn, opts) do
    key = Keyword.fetch!(opts, :key)
    limits = Application.get_env(:tmux_rm, :rate_limits, @default_limits)
    {max_requests, window} = Map.get(limits, key, {10, 60})

    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case TmuxRmWeb.RateLimitStore.check(ip, key, {max_requests, window}) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after} ->
        Logger.warning("Rate limit exceeded: #{ip} on #{key}")

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(429)
        |> json(%{error: "rate_limited", retry_after: retry_after})
        |> halt()
    end
  end
end
