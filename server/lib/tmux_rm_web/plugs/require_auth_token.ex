defmodule TmuxRmWeb.Plugs.RequireAuthToken do
  @moduledoc "Verifies Bearer token for API routes."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if TmuxRm.Auth.auth_enabled?() do
      max_age = TmuxRm.Auth.session_ttl_seconds()

      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, _data} <-
             Phoenix.Token.verify(TmuxRmWeb.Endpoint, "api_token", token, max_age: max_age) do
        conn
      else
        _ ->
          conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
      end
    else
      conn
    end
  end
end
