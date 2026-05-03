defmodule TermigateWeb.Plugs.RequireAuthToken do
  @moduledoc "Verifies Bearer token for API routes."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if Termigate.Auth.auth_enabled?() do
      max_age = Termigate.Auth.session_ttl_seconds()
      current_version = Termigate.Auth.auth_version()

      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, %{auth_version: claim_version}} <-
             Phoenix.Token.verify(TermigateWeb.Endpoint, "api_token", token, max_age: max_age),
           true <- is_binary(claim_version) and claim_version == current_version do
        conn
      else
        _ ->
          Logger.warning(
            "API auth rejected: invalid or missing token, ip=#{conn.remote_ip |> :inet.ntoa() |> to_string()}"
          )

          conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
      end
    else
      # Fail closed before first-run setup: refuse API/MCP access until an
      # admin account is created via /setup. Without this, any caller that
      # reaches a fresh instance can drive tmux through the API or MCP.
      Logger.warning(
        "API access denied: setup not complete, ip=#{conn.remote_ip |> :inet.ntoa() |> to_string()}"
      )

      conn |> put_status(503) |> json(%{error: "setup_required"}) |> halt()
    end
  end
end
