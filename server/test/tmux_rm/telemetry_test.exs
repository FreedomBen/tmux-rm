defmodule TmuxRm.TelemetryTest do
  use ExUnit.Case, async: true

  test "pane_stream_count emits telemetry event" do
    ref = make_ref()
    self_pid = self()

    :telemetry.attach(
      "test-pane-stream-count-#{ref |> inspect()}",
      [:tmux_rm, :pane_streams],
      fn _event, measurements, _metadata, _config ->
        send(self_pid, {:telemetry, measurements})
      end,
      nil
    )

    TmuxRmWeb.Telemetry.pane_stream_count()
    assert_receive {:telemetry, %{active: count}} when is_integer(count)
  end

  test "rate_limit_table_size emits telemetry event" do
    ref = make_ref()
    self_pid = self()

    :telemetry.attach(
      "test-rate-limit-size-#{ref |> inspect()}",
      [:tmux_rm, :rate_limit_store],
      fn _event, measurements, _metadata, _config ->
        send(self_pid, {:telemetry, measurements})
      end,
      nil
    )

    TmuxRmWeb.Telemetry.rate_limit_table_size()
    assert_receive {:telemetry, %{size: size}} when is_integer(size)
  end

  test "metrics/0 returns a list of metric definitions" do
    metrics = TmuxRmWeb.Telemetry.metrics()
    assert is_list(metrics)
    assert length(metrics) > 0
  end
end
