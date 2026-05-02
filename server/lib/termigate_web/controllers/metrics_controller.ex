defmodule TermigateWeb.MetricsController do
  use TermigateWeb, :controller

  def index(conn, _params) do
    metrics_token = Application.get_env(:termigate, :metrics_token)

    if metrics_token do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          if Plug.Crypto.secure_compare(token, metrics_token) do
            json(conn, collect_metrics())
          else
            conn |> put_status(401) |> json(%{error: "unauthorized"})
          end

        _ ->
          conn |> put_status(401) |> json(%{error: "unauthorized"})
      end
    else
      json(conn, collect_metrics())
    end
  end

  defp collect_metrics do
    active_streams =
      DynamicSupervisor.count_children(Termigate.PaneStreamSupervisor)[:active] || 0

    memory = :erlang.memory()
    uptime_seconds = div(System.monotonic_time(:millisecond) - boot_time(), 1000)

    %{
      active_pane_streams: active_streams,
      uptime_seconds: uptime_seconds,
      auth_mode: auth_mode(),
      vm: %{
        memory_total_mb: Float.round(memory[:total] / 1_048_576, 2),
        memory_processes_mb: Float.round(memory[:processes] / 1_048_576, 2),
        memory_binary_mb: Float.round(memory[:binary] / 1_048_576, 2),
        process_count: :erlang.system_info(:process_count),
        run_queue: :erlang.statistics(:total_run_queue_lengths_all)
      }
    }
  end

  defp auth_mode do
    cond do
      Application.get_env(:termigate, :auth_token) -> "token"
      Termigate.Auth.auth_enabled?() -> "credentials"
      true -> "disabled"
    end
  end

  defp boot_time do
    case :persistent_term.get(:termigate_boot_time, nil) do
      nil ->
        now = System.monotonic_time(:millisecond)
        :persistent_term.put(:termigate_boot_time, now)
        now

      time ->
        time
    end
  end
end
