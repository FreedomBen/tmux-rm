defmodule TmuxRmWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # PaneStream
      counter("tmux_rm.pane_stream.start.total"),
      counter("tmux_rm.pane_stream.stop.total"),
      sum("tmux_rm.pane_stream.output.bytes"),
      sum("tmux_rm.pane_stream.input.bytes"),
      last_value("tmux_rm.pane_stream.viewer_change.count"),
      counter("tmux_rm.pane_stream.recovery.total"),

      # Auth
      counter("tmux_rm.auth.login.success.total"),
      counter("tmux_rm.auth.login.failure.total"),
      counter("tmux_rm.auth.rate_limited.total"),

      # SessionPoller
      summary("tmux_rm.session_poller.poll.duration_ms"),
      last_value("tmux_rm.session_poller.poll.session_count"),

      # Periodic measurements
      last_value("tmux_rm.pane_streams.active"),
      last_value("tmux_rm.rate_limit_store.size"),

      # VM Metrics
      last_value("vm.memory.total"),
      last_value("vm.memory.processes"),
      last_value("vm.memory.binary"),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.system_counts.process_count")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :pane_stream_count, []},
      {__MODULE__, :rate_limit_table_size, []}
    ]
  end

  def pane_stream_count do
    count = DynamicSupervisor.count_children(TmuxRm.PaneStreamSupervisor)[:active] || 0
    :telemetry.execute([:tmux_rm, :pane_streams], %{active: count}, %{})
  end

  def rate_limit_table_size do
    size =
      try do
        :ets.info(:rate_limit_store, :size) || 0
      rescue
        _ -> 0
      end

    :telemetry.execute([:tmux_rm, :rate_limit_store], %{size: size}, %{})
  end
end
