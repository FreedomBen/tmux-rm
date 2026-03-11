defmodule TmuxRm.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    fifo_dir = Application.get_env(:tmux_rm, :fifo_dir)

    # Clean up and recreate FIFO directory on boot
    File.rm_rf(fifo_dir)
    File.mkdir_p!(fifo_dir)

    children = [
      TmuxRmWeb.Telemetry,
      {Registry, keys: :unique, name: TmuxRm.PaneRegistry},
      {DynamicSupervisor,
       name: TmuxRm.PaneStreamSupervisor,
       max_children: Application.get_env(:tmux_rm, :max_pane_streams, 100)},
      {Phoenix.PubSub, name: TmuxRm.PubSub},
      TmuxRm.SessionPoller,
      TmuxRm.Config,
      TmuxRmWeb.RateLimitStore,
      {DynamicSupervisor, name: TmuxRm.LayoutPollerSupervisor, strategy: :one_for_one},
      TmuxRmWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: TmuxRm.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Non-blocking tmux availability check
    check_tmux_availability()

    # Warn if exposed without auth
    check_auth_warning()

    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    TmuxRmWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp check_auth_warning do
    unless TmuxRm.Auth.auth_enabled?() do
      http_config = Application.get_env(:tmux_rm, TmuxRmWeb.Endpoint, []) |> Keyword.get(:http, [])
      ip = Keyword.get(http_config, :ip)

      if ip in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}] do
        Logger.warning(
          "Listening on 0.0.0.0 with no authentication configured. " <>
            "Set up auth via `cd server && mix rca.setup` or set RCA_AUTH_TOKEN."
        )
      end
    end
  end

  defp check_tmux_availability do
    spawn(fn ->
      try do
        runner = Application.get_env(:tmux_rm, :command_runner)

        case runner.run(["list-sessions"]) do
          {:ok, _} ->
            Logger.info("tmux is available and server is running")

          {:error, {stderr, _code}} ->
            if String.contains?(stderr, "no server running") do
              Logger.info("tmux is available but no server running (normal — starts on demand)")
            else
              Logger.warning("tmux check failed: #{stderr}")
            end
        end
      rescue
        _ ->
          Logger.warning(
            "tmux binary not found. PATH: #{System.get_env("PATH")}. " <>
              "Install tmux 3.1+ to use this application."
          )
      end
    end)
  end
end
