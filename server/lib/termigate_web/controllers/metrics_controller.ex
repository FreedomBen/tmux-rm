defmodule TermigateWeb.MetricsController do
  use TermigateWeb, :controller

  @moduledoc """
  Operational metrics endpoint.

  Access policy (in order):

    1. Loopback peers (`127.0.0.1`, `::1`) always get metrics. Operators are
       expected to scrape from a sidecar or SSH tunnel by default.
    2. If `TERMIGATE_PUBLIC_METRICS=true` is set, anyone can scrape over the
       public listener. This is the explicit opt-in for remote scraping.
    3. If `TERMIGATE_METRICS_TOKEN` is set, a valid `Authorization: Bearer ...`
       header from any peer is accepted.
    4. Otherwise (remote peer, no public flag, no valid token) the response
       is `404 not_found` so the route's existence is not advertised.

  The payload deliberately omits high-signal reconnaissance fields like
  `auth_mode` and `active_pane_streams`; those would let a passive scraper
  detect an unauthenticated instance or watch live-session activity.
  """

  def index(conn, _params) do
    cond do
      loopback?(conn.remote_ip) or public_metrics?() ->
        json(conn, collect_metrics())

      metrics_token = configured_token() ->
        if valid_bearer?(conn, metrics_token) do
          json(conn, collect_metrics())
        else
          conn |> put_status(401) |> json(%{error: "unauthorized"})
        end

      true ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  defp configured_token do
    case Application.get_env(:termigate, :metrics_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp public_metrics? do
    case Application.get_env(:termigate, :public_metrics) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp valid_bearer?(conn, expected) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Plug.Crypto.secure_compare(token, expected)
      _ -> false
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp collect_metrics do
    memory = :erlang.memory()
    uptime_seconds = div(System.monotonic_time(:millisecond) - boot_time(), 1000)

    %{
      uptime_seconds: uptime_seconds,
      vm: %{
        memory_total_mb: Float.round(memory[:total] / 1_048_576, 2),
        memory_processes_mb: Float.round(memory[:processes] / 1_048_576, 2),
        memory_binary_mb: Float.round(memory[:binary] / 1_048_576, 2),
        process_count: :erlang.system_info(:process_count),
        run_queue: :erlang.statistics(:total_run_queue_lengths_all)
      }
    }
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
