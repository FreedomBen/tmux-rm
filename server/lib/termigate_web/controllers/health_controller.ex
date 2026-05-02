defmodule TermigateWeb.HealthController do
  use TermigateWeb, :controller

  # Liveness probe: minimal response so unauthenticated callers cannot use it
  # for reconnaissance. Detailed VM stats and auth mode live behind the
  # metrics_token gate on /metrics. tmux reachability stays here because
  # container/k8s healthchecks need a single signal that the server is
  # functional, not just listening.
  def healthz(conn, _params) do
    case Termigate.SessionPoller.tmux_status() do
      :ok ->
        conn |> put_status(200) |> json(%{status: "ok", tmux: "ok"})

      :no_server ->
        conn |> put_status(200) |> json(%{status: "ok", tmux: "no_server"})

      :not_found ->
        conn |> put_status(503) |> json(%{status: "error", tmux: "not_found"})

      {:error, _msg} ->
        conn |> put_status(503) |> json(%{status: "error", tmux: "error"})
    end
  end
end
