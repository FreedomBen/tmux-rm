defmodule Termigate.PaneStream do
  @moduledoc """
  GenServer that bridges a tmux pane to viewers via pipe-pane + FIFO.

  Manages the ring buffer, viewer lifecycle (subscribe/unsubscribe/grace period),
  output coalescing, and pane death detection.
  """

  use GenServer

  alias Termigate.RingBuffer

  require Logger

  @max_recovery_attempts 3
  @recovery_window_ms 60_000

  # --- Public API ---

  @doc """
  Subscribe the calling process to a pane's output stream.
  Looks up or starts a PaneStream, registers the caller as a viewer,
  and returns the buffered history.
  """
  def subscribe(target) do
    pubsub_topic = "pane:#{target}"
    Phoenix.PubSub.subscribe(Termigate.PubSub, pubsub_topic)

    case ensure_started(target) do
      {:ok, pid} ->
        try do
          case GenServer.call(pid, {:subscribe, self()}) do
            {:ok, history} ->
              {:ok, history, pid}

            {:error, reason} ->
              Phoenix.PubSub.unsubscribe(Termigate.PubSub, pubsub_topic)
              {:error, reason}
          end
        catch
          :exit, _ ->
            Phoenix.PubSub.unsubscribe(Termigate.PubSub, pubsub_topic)
            {:error, :not_ready}
        end

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Termigate.PubSub, pubsub_topic)
        {:error, reason}
    end
  end

  @doc "Unsubscribe the calling process from a pane's output stream."
  def unsubscribe(target) do
    case lookup(target) do
      {:ok, pid} ->
        GenServer.call(pid, {:unsubscribe, self()})

      {:error, :not_found} ->
        :ok
    end
  end

  @doc "Send keyboard input to the pane. Auto-starts a PaneStream if needed."
  def send_keys(target, data) when is_binary(data) do
    case ensure_started(target) do
      {:ok, pid} -> GenServer.call(pid, {:send_keys, data}, 10_000)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Read the current buffer contents without subscribing as a viewer."
  def read_buffer(target) do
    case lookup(target) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :read_buffer)
        catch
          :exit, _ -> {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "Resize the pane. Validates bounds and calls tmux resize-pane."
  def resize(target, cols, rows) when is_integer(cols) and is_integer(rows) do
    cols = cols |> max(1) |> min(500)
    rows = rows |> max(1) |> min(200)

    case lookup(target) do
      {:ok, pid} -> GenServer.call(pid, {:resize, cols, rows})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Resize the pane and re-capture scrollback. Used on initial join so history matches client dimensions."
  def resize_and_capture(target, cols, rows) when is_integer(cols) and is_integer(rows) do
    cols = cols |> max(1) |> min(500)
    rows = rows |> max(1) |> min(200)

    case lookup(target) do
      {:ok, pid} -> GenServer.call(pid, {:resize_and_capture, cols, rows})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # --- GenServer Implementation ---

  def child_spec(target) do
    %{
      id: {__MODULE__, target},
      start: {__MODULE__, :start_link, [target]},
      restart: :transient
    }
  end

  def start_link(target) do
    GenServer.start_link(__MODULE__, target,
      name: {:via, Registry, {Termigate.PaneRegistry, {:pane, target}}}
    )
  end

  @impl true
  def init(target) do
    notification_config = read_notification_config()

    state = %{
      target: target,
      pane_id: nil,
      pipe_port: nil,
      viewers: MapSet.new(),
      buffer: RingBuffer.new(),
      status: :starting,
      grace_timer_ref: nil,
      port_recovery: %{attempts: 0, window_start: nil},
      coalesce_acc: [],
      coalesce_timer: nil,
      coalesce_bytes: 0,
      notification_mode: notification_config["mode"] || "disabled",
      idle_timer_ref: nil,
      idle_threshold_ms: (notification_config["idle_threshold"] || 10) * 1000,
      last_output_at: nil,
      had_recent_activity: false,
      marker_partial: <<>>
    }

    Phoenix.PubSub.subscribe(Termigate.PubSub, "config")

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    case setup_pipeline(state) do
      {:ok, state} ->
        Logger.info("PaneStream started: #{state.target} (pane_id: #{state.pane_id})")

        :telemetry.execute(
          [:termigate, :pane_stream, :start],
          %{system_time: System.system_time()},
          %{target: state.target, pane_id: state.pane_id}
        )

        {:noreply, %{state | status: :streaming}}

      {:error, reason} ->
        Logger.warning("PaneStream setup failed for #{state.target}: #{inspect(reason)}")
        {:stop, :normal, %{state | status: :dead}}
    end
  end

  @impl true
  def handle_call({:subscribe, _pid}, _from, %{status: :starting} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:subscribe, _pid}, _from, %{status: :dead} = state) do
    {:reply, {:error, :pane_dead}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    old_count = MapSet.size(state.viewers)
    new_viewers = MapSet.put(state.viewers, pid)
    new_count = MapSet.size(new_viewers)

    state =
      if state.grace_timer_ref do
        Process.cancel_timer(state.grace_timer_ref)
        %{state | grace_timer_ref: nil}
      else
        state
      end

    if new_count != old_count do
      Logger.info("PaneStream #{state.target}: viewers #{old_count} → #{new_count}")

      :telemetry.execute(
        [:termigate, :pane_stream, :viewer_change],
        %{count: new_count},
        %{target: state.target}
      )
    end

    history = RingBuffer.read(state.buffer)
    {:reply, {:ok, history}, %{state | viewers: new_viewers}}
  end

  def handle_call(:read_buffer, _from, state) do
    {:reply, {:ok, RingBuffer.read(state.buffer)}, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    old_count = MapSet.size(state.viewers)
    new_viewers = MapSet.delete(state.viewers, pid)
    new_count = MapSet.size(new_viewers)

    if new_count != old_count do
      Logger.info("PaneStream #{state.target}: viewers #{old_count} → #{new_count}")
    end

    state = %{state | viewers: new_viewers}
    state = maybe_start_grace_period(state)
    {:reply, :ok, state}
  end

  def handle_call({:send_keys, _data}, _from, %{status: :dead} = state) do
    {:reply, {:error, :pane_dead}, state}
  end

  def handle_call({:send_keys, _data}, _from, %{status: :starting} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:send_keys, data}, _from, state) do
    input_limit = Application.get_env(:termigate, :input_size_limit, 131_072)

    if byte_size(data) > input_limit do
      {:reply, {:error, :input_too_large}, state}
    else
      result = send_hex_keys(state.pane_id, data)

      if result == :ok do
        :telemetry.execute(
          [:termigate, :pane_stream, :input],
          %{bytes: byte_size(data)},
          %{target: state.target}
        )
      end

      {:reply, result, state}
    end
  end

  def handle_call({:resize, _cols, _rows}, _from, %{status: status} = state)
      when status in [:dead, :starting] do
    {:reply, {:error, status}, state}
  end

  def handle_call({:resize_and_capture, _cols, _rows}, _from, %{status: status} = state)
      when status in [:dead, :starting] do
    {:reply, {:error, status}, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    case do_resize(state, cols, rows) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:resize_and_capture, cols, rows}, _from, state) do
    case do_resize(state, cols, rows) do
      {:ok, state} ->
        # Give tmux a moment to reflow content at the new dimensions
        Process.sleep(50)
        runner = command_runner()

        # Capture scrollback history in addition to the visible screen.
        # After resize, tmux has reflowed content to the new width, so
        # scrollback is safe to send.  300 lines gives mobile clients
        # meaningful scroll-back without excessive payload.
        case runner.run(["capture-pane", "-p", "-e", "-S", "-300", "-t", state.pane_id]) do
          {:ok, screen} ->
            screen_data = build_screen_data(runner, state.pane_id, screen)

            Logger.debug(
              "resize_and_capture: #{cols}x#{rows}, got #{byte_size(screen_data)} bytes"
            )

            buffer =
              state.buffer
              |> RingBuffer.clear()
              |> RingBuffer.append(screen_data)

            {:reply, {:ok, screen_data}, %{state | buffer: buffer}}

          {:error, _} ->
            {:reply, {:ok, RingBuffer.read(state.buffer)}, state}
        end

      {:error, msg} ->
        {:reply, {:error, msg}, state}
    end
  end

  defp do_resize(state, cols, rows) do
    case command_runner().run([
           "resize-pane",
           "-t",
           state.pane_id,
           "-x",
           to_string(cols),
           "-y",
           to_string(rows)
         ]) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Termigate.PubSub,
          "pane:#{state.target}",
          {:pane_resized, cols, rows}
        )

        {:ok, state}

      {:error, {msg, _}} ->
        {:error, msg}
    end
  end

  # Port data — output from the FIFO (pipe-pane output)
  @impl true
  def handle_info({port, {:data, bytes}}, %{pipe_port: port} = state) do
    max_bytes = Application.get_env(:termigate, :output_coalesce_max_bytes, 32_768)
    coalesce_ms = Application.get_env(:termigate, :output_coalesce_ms, 3)

    new_acc = [state.coalesce_acc | bytes]
    new_bytes = state.coalesce_bytes + byte_size(bytes)

    state = %{state | coalesce_acc: new_acc, coalesce_bytes: new_bytes}

    cond do
      new_bytes >= max_bytes ->
        {:noreply, flush_output(state)}

      state.coalesce_timer == nil ->
        ref = Process.send_after(self(), :flush_output, coalesce_ms)
        {:noreply, %{state | coalesce_timer: ref}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:flush_output, state) do
    {:noreply, flush_output(%{state | coalesce_timer: nil})}
  end

  # Port exit — cat on FIFO exited
  def handle_info({port, {:exit_status, code}}, %{pipe_port: port} = state) do
    state = flush_output(%{state | pipe_port: nil})
    Logger.warning("PaneStream #{state.target}: port exited (code #{code})")

    if check_pane_alive(state.pane_id) do
      # Pane alive — attempt pipeline recovery
      case attempt_recovery(state) do
        {:ok, state} ->
          broadcast(
            state.target,
            {:pane_reconnected, state.target, RingBuffer.read(state.buffer)}
          )

          {:noreply, state}

        {:error, _reason} ->
          handle_pane_death(state)
      end
    else
      handle_pane_death(state)
    end
  end

  # Viewer process died
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    old_count = MapSet.size(state.viewers)
    new_viewers = MapSet.delete(state.viewers, pid)
    new_count = MapSet.size(new_viewers)

    if new_count != old_count do
      Logger.info("PaneStream #{state.target}: viewer down, #{old_count} → #{new_count}")
    end

    state = %{state | viewers: new_viewers}
    state = maybe_start_grace_period(state)
    {:noreply, state}
  end

  # Grace period expired
  def handle_info(:grace_period_expired, state) do
    state = %{state | grace_timer_ref: nil}

    if MapSet.size(state.viewers) == 0 do
      Logger.info("PaneStream #{state.target}: grace period expired, shutting down")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # Idle timeout — broadcast idle notification
  def handle_info(:idle_timeout, state) do
    state = %{state | idle_timer_ref: nil}

    if state.had_recent_activity do
      elapsed_ms =
        case state.last_output_at do
          nil -> state.idle_threshold_ms
          ts -> System.monotonic_time(:millisecond) - ts
        end

      broadcast(state.target, {:pane_idle, state.target, elapsed_ms})
      {:noreply, %{state | had_recent_activity: false}}
    else
      {:noreply, state}
    end
  end

  # Config changed — update notification settings
  def handle_info({:config_changed, config}, state) do
    notification_config = config["notifications"] || %{}
    new_mode = notification_config["mode"] || "disabled"
    new_threshold_ms = (notification_config["idle_threshold"] || 10) * 1000
    old_mode = state.notification_mode

    state = %{state | notification_mode: new_mode, idle_threshold_ms: new_threshold_ms}

    state =
      cond do
        new_mode == "disabled" ->
          cancel_idle_timer(state)

        old_mode == "disabled" and state.had_recent_activity ->
          ref = Process.send_after(self(), :idle_timeout, new_threshold_ms)
          %{state | idle_timer_ref: ref}

        old_mode != "disabled" and state.idle_timer_ref != nil ->
          # Reschedule with new threshold, adjusted for elapsed time
          elapsed =
            case state.last_output_at do
              nil -> 0
              ts -> System.monotonic_time(:millisecond) - ts
            end

          remaining = max(0, new_threshold_ms - elapsed)
          state = cancel_idle_timer(state)
          ref = Process.send_after(self(), :idle_timeout, remaining)
          %{state | idle_timer_ref: ref}

        true ->
          state
      end

    {:noreply, state}
  end

  # Supersede flow
  @impl true
  def handle_cast({:superseded, new_target}, state) do
    Logger.info("PaneStream #{state.target}: superseded by #{new_target}")
    cleanup_pipeline(state)
    broadcast(state.target, {:pane_superseded, state.target, new_target})
    {:stop, :normal, %{state | status: :shutting_down}}
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:termigate, :pane_stream, :stop],
      %{system_time: System.system_time()},
      %{target: state.target, reason: reason}
    )

    state = cancel_idle_timer(state)
    state = flush_output(state)
    cleanup_pipeline(%{state | status: :shutting_down})
    :ok
  end

  # --- Private Functions ---

  defp setup_pipeline(state) do
    runner = command_runner()
    target = state.target
    fifo_dir = Application.get_env(:termigate, :fifo_dir)

    with {:ok, pane_id} <- resolve_pane_id(runner, target),
         :ok <- register_pane_id(pane_id),
         :ok <- detach_existing_pipe(runner, pane_id),
         fifo_path = fifo_path(fifo_dir, pane_id),
         :ok <- setup_fifo(fifo_path),
         {:ok, port} <- start_cat_port(fifo_path),
         :ok <- attach_pipe(runner, pane_id, fifo_path),
         {:ok, buffer} <- capture_scrollback(runner, pane_id) do
      {:ok, %{state | pane_id: pane_id, pipe_port: port, buffer: buffer}}
    end
  end

  defp resolve_pane_id(runner, target) do
    case runner.run(["display-message", "-p", "-t", target, "\#{pane_id}"]) do
      {:ok, pane_id} -> {:ok, String.trim(pane_id)}
      {:error, {msg, _}} -> {:error, {:resolve_failed, msg}}
    end
  end

  defp register_pane_id(pane_id) do
    case Registry.register(Termigate.PaneRegistry, {:pane_id, pane_id}, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp detach_existing_pipe(runner, pane_id) do
    # Detach any existing pipe-pane (ignore errors)
    runner.run(["pipe-pane", "-t", pane_id])
    :ok
  end

  defp setup_fifo(fifo_path) do
    File.rm(fifo_path)
    File.mkdir_p!(Path.dirname(fifo_path))

    case System.cmd("mkfifo", ["-m", "0600", fifo_path]) do
      {_, 0} -> :ok
      {err, code} -> {:error, {:mkfifo_failed, err, code}}
    end
  end

  defp start_cat_port(fifo_path) do
    try do
      port =
        Port.open({:spawn_executable, "/usr/bin/cat"}, [
          {:args, [fifo_path]},
          :binary,
          :stream,
          :exit_status
        ])

      {:ok, port}
    rescue
      e -> {:error, {:port_failed, Exception.message(e)}}
    end
  end

  defp attach_pipe(runner, pane_id, fifo_path) do
    case runner.run(["pipe-pane", "-t", pane_id, "-o", "cat >> #{fifo_path}"]) do
      {:ok, _} -> :ok
      {:error, {msg, _}} -> {:error, {:pipe_attach_failed, msg}}
    end
  end

  defp capture_scrollback(runner, pane_id) do
    # Under memory pressure, use minimum buffer size for new streams
    watermark = Application.get_env(:termigate, :memory_high_watermark, 805_306_368)
    memory_high? = :erlang.memory(:total) > watermark

    buffer =
      if memory_high? do
        min_size = Application.get_env(:termigate, :ring_buffer_min_size, 524_288)
        Logger.info("Memory above high watermark, using min ring buffer size (#{min_size})")
        RingBuffer.new(min_size)
      else
        # Query pane dimensions for buffer sizing
        case runner.run([
               "display-message",
               "-p",
               "-t",
               pane_id,
               "\#{history_limit}\t\#{pane_width}"
             ]) do
          {:ok, dims} ->
            case String.split(String.trim(dims), "\t") do
              [hist, width] ->
                history_limit = parse_int(hist, 2000)
                pane_width = parse_int(width, 120)
                capacity = history_limit * pane_width
                RingBuffer.new(capacity)

              _ ->
                RingBuffer.new()
            end

          _ ->
            RingBuffer.new()
        end
      end

    # Capture visible screen only (no -S flag). Full scrollback history
    # contains content formatted at previous pane dimensions which renders
    # incorrectly when the browser terminal has different dimensions.
    buffer =
      case runner.run(["capture-pane", "-p", "-e", "-t", pane_id]) do
        {:ok, screen} ->
          screen_data = build_screen_data(runner, pane_id, screen)

          buffer
          |> RingBuffer.clear()
          |> RingBuffer.append(screen_data)

        {:error, _} ->
          buffer
      end

    {:ok, buffer}
  end

  # Build screen data that xterm.js can render correctly.
  # capture-pane -p uses bare LF (\n) between lines, but xterm.js treats LF
  # as line-feed only (no carriage return), causing a staircase effect.
  # Real tmux redraws using cursor positioning; we emulate that by converting
  # LF to CRLF and restoring the cursor position.
  defp build_screen_data(runner, pane_id, screen) do
    {cursor_x, cursor_y} = get_cursor_position(runner, pane_id)

    # Convert LF to CRLF for xterm.js, strip trailing CRLF
    screen_crlf =
      screen
      |> String.replace("\n", "\r\n")
      |> String.trim_trailing("\r\n")

    IO.iodata_to_binary([
      # Clear screen and home cursor for a clean slate
      "\e[2J\e[H",
      screen_crlf,
      # Restore cursor to match tmux's actual cursor position (1-indexed)
      "\e[#{cursor_y + 1};#{cursor_x + 1}H"
    ])
  end

  defp get_cursor_position(runner, pane_id) do
    case runner.run([
           "display-message",
           "-p",
           "-t",
           pane_id,
           "\#{cursor_x}\t\#{cursor_y}"
         ]) do
      {:ok, result} ->
        case String.split(String.trim(result), "\t") do
          [cx, cy] -> {parse_int(cx, 0), parse_int(cy, 0)}
          _ -> {0, 0}
        end

      {:error, _} ->
        {0, 0}
    end
  end

  defp flush_output(%{coalesce_bytes: 0} = state), do: state

  defp flush_output(state) do
    data = IO.iodata_to_binary(state.coalesce_acc)

    # Prepend any partial marker from previous chunk, with staleness guard
    marker_partial =
      if byte_size(state.marker_partial) > 256, do: <<>>, else: state.marker_partial

    scan_input = <<marker_partial::binary, data::binary>>

    # Scan for OSC markers, strip them, and broadcast notification events
    {stripped_data, new_marker_partial} =
      scan_and_strip_notifications(scan_input, state.target)

    buffer = RingBuffer.append(state.buffer, stripped_data)

    if byte_size(stripped_data) > 0 do
      broadcast(state.target, {:pane_output, state.target, stripped_data})
    end

    :telemetry.execute(
      [:termigate, :pane_stream, :output],
      %{bytes: byte_size(stripped_data)},
      %{target: state.target}
    )

    if state.coalesce_timer do
      Process.cancel_timer(state.coalesce_timer)
    end

    state = %{
      state
      | buffer: buffer,
        coalesce_acc: [],
        coalesce_timer: nil,
        coalesce_bytes: 0,
        marker_partial: new_marker_partial
    }

    # Idle tracking for notifications
    state = %{
      state
      | last_output_at: System.monotonic_time(:millisecond),
        had_recent_activity: true
    }

    if state.notification_mode != "disabled" do
      state = cancel_idle_timer(state)
      ref = Process.send_after(self(), :idle_timeout, state.idle_threshold_ms)
      %{state | idle_timer_ref: ref}
    else
      state
    end
  end

  defp send_hex_keys(pane_id, data) do
    chunk_size = 65_536
    chunks = chunk_binary(data, chunk_size)

    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      hex_values =
        chunk
        |> :binary.bin_to_list()
        |> Enum.map(&Integer.to_string(&1, 16))
        |> Enum.map(&String.pad_leading(&1, 2, "0"))

      args = ["send-keys", "-H", "-t", pane_id | hex_values]

      case command_runner().run(args) do
        {:ok, _} -> {:cont, :ok}
        {:error, {msg, _}} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp chunk_binary(<<>>, _size), do: []
  defp chunk_binary(data, size) when byte_size(data) <= size, do: [data]

  defp chunk_binary(data, size) do
    <<chunk::binary-size(size), rest::binary>> = data
    [chunk | chunk_binary(rest, size)]
  end

  defp check_pane_alive(pane_id) do
    case command_runner().run(["display-message", "-p", "-t", pane_id, "\#{pane_id}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp attempt_recovery(state) do
    now = System.monotonic_time(:millisecond)
    recovery = state.port_recovery

    # Reset window if expired
    recovery =
      if recovery.window_start && now - recovery.window_start > @recovery_window_ms do
        %{attempts: 0, window_start: nil}
      else
        recovery
      end

    if recovery.attempts >= @max_recovery_attempts do
      Logger.warning("PaneStream #{state.target}: max recovery attempts reached")
      {:error, :max_recovery_attempts}
    else
      recovery = %{
        attempts: recovery.attempts + 1,
        window_start: recovery.window_start || now
      }

      Logger.warning("PaneStream #{state.target}: recovery attempt #{recovery.attempts}")

      :telemetry.execute(
        [:termigate, :pane_stream, :recovery],
        %{attempt: recovery.attempts},
        %{target: state.target}
      )

      fifo_dir = Application.get_env(:termigate, :fifo_dir)
      fifo_path = fifo_path(fifo_dir, state.pane_id)
      runner = command_runner()

      with :ok <- setup_fifo(fifo_path),
           {:ok, port} <- start_cat_port(fifo_path),
           :ok <- attach_pipe(runner, state.pane_id, fifo_path) do
        {:ok, %{state | pipe_port: port, port_recovery: recovery}}
      end
    end
  end

  defp handle_pane_death(state) do
    Logger.info("PaneStream #{state.target}: pane is dead, shutting down")

    state =
      if state.grace_timer_ref do
        Process.cancel_timer(state.grace_timer_ref)
        %{state | grace_timer_ref: nil}
      else
        state
      end

    state = cancel_idle_timer(state)

    broadcast(state.target, {:pane_dead, state.target})
    cleanup_fifo(state)
    {:stop, :normal, %{state | status: :dead}}
  end

  defp maybe_start_grace_period(state) do
    if MapSet.size(state.viewers) == 0 and state.grace_timer_ref == nil do
      grace_ms = Application.get_env(:termigate, :pane_stream_grace_period, 30_000)
      ref = Process.send_after(self(), :grace_period_expired, grace_ms)
      %{state | grace_timer_ref: ref}
    else
      state
    end
  end

  defp cleanup_pipeline(state) do
    if state.pane_id do
      command_runner().run(["pipe-pane", "-t", state.pane_id])
    end

    close_port(state.pipe_port)
    cleanup_fifo(state)
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    try do
      # Kill the OS process to ensure it doesn't linger
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)

        nil ->
          :ok
      end

      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp cleanup_fifo(state) do
    if state.pane_id do
      fifo_dir = Application.get_env(:termigate, :fifo_dir)
      File.rm(fifo_path(fifo_dir, state.pane_id))
    end
  end

  defp fifo_path(fifo_dir, pane_id) do
    # Strip the % prefix from tmux pane IDs to avoid tmux interpreting
    # %NNN as format specifiers in pipe-pane command strings
    safe_id = String.replace(pane_id, "%", "")
    Path.join(fifo_dir, "pane-#{safe_id}.fifo")
  end

  defp broadcast(target, message) do
    Phoenix.PubSub.broadcast(Termigate.PubSub, "pane:#{target}", message)
  end

  defp ensure_started(target) do
    case lookup(target) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        case DynamicSupervisor.start_child(Termigate.PaneStreamSupervisor, {__MODULE__, target}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lookup(target) do
    case Registry.lookup(Termigate.PaneRegistry, {:pane, target}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  # --- OSC marker scanning ---

  @notification_marker "\e]termigate;"

  # Scans data for termigate OSC markers, strips them, and broadcasts events.
  # Returns {stripped_data, marker_partial} where marker_partial is an incomplete
  # marker at the end of the chunk to be prepended to the next chunk.
  defp scan_and_strip_notifications(data, target) do
    do_scan_and_strip(data, target, <<>>)
  end

  defp do_scan_and_strip(data, target, acc) do
    case :binary.match(data, @notification_marker) do
      {start, len} ->
        before = binary_part(data, 0, start)
        rest = binary_part(data, start + len, byte_size(data) - start - len)

        case :binary.match(rest, <<7>>) do
          {end_pos, _} ->
            payload = binary_part(rest, 0, end_pos)
            parse_and_broadcast_notification(payload, target)
            remaining = binary_part(rest, end_pos + 1, byte_size(rest) - end_pos - 1)
            do_scan_and_strip(remaining, target, <<acc::binary, before::binary>>)

          :nomatch ->
            # Incomplete marker at end of chunk — store as partial
            {<<acc::binary, before::binary>>, binary_part(data, start, byte_size(data) - start)}
        end

      :nomatch ->
        {<<acc::binary, data::binary>>, <<>>}
    end
  end

  defp parse_and_broadcast_notification(payload, target) do
    case String.split(payload, ";") do
      ["cmd_done", exit_code, cmd_name, duration] ->
        sanitized_name =
          cmd_name
          |> String.slice(0, 128)
          |> String.replace(~r/[^\x20-\x7E]/, "")

        with {parsed_exit_code, _} <- Integer.parse(exit_code),
             {parsed_duration, _} <- Integer.parse(duration) do
          broadcast(
            target,
            {:command_finished, target,
             %{
               exit_code: parsed_exit_code,
               command: sanitized_name,
               duration_seconds: parsed_duration
             }}
          )
        end

      _ ->
        :ok
    end
  end

  defp cancel_idle_timer(%{idle_timer_ref: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer_ref: nil}
  end

  defp read_notification_config do
    try do
      config = Termigate.Config.get()
      config["notifications"] || %{}
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  defp command_runner, do: Application.get_env(:termigate, :command_runner)
end
