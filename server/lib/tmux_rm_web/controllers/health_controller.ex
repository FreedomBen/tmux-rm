defmodule TmuxRmWeb.HealthController do
  use TmuxRmWeb, :controller

  def healthz(conn, _params) do
    tmux_status = TmuxRm.SessionPoller.tmux_status()
    active_streams = DynamicSupervisor.count_children(TmuxRm.PaneStreamSupervisor)[:active] || 0
    memory = :erlang.memory()

    auth_mode =
      cond do
        Application.get_env(:tmux_rm, :auth_token) -> "token"
        TmuxRm.Auth.auth_enabled?() -> "credentials"
        true -> "disabled"
      end

    {http_status, base_body} =
      case tmux_status do
        :ok ->
          {200, %{status: "ok", tmux: "ok"}}

        :no_server ->
          {200, %{status: "ok", tmux: "no_server"}}

        :not_found ->
          {503, %{status: "error", tmux: "not_found"}}

        {:error, msg} ->
          {503, %{status: "error", tmux: "error", message: msg}}
      end

    body =
      Map.merge(base_body, %{
        active_pane_streams: active_streams,
        vm_memory_mb: Float.round(memory[:total] / 1_048_576, 2),
        auth_mode: auth_mode
      })

    conn
    |> put_status(http_status)
    |> json(body)
  end
end
