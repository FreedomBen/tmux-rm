defmodule TmuxRmWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel for binary terminal I/O.

  Handles keyboard input and terminal output, avoiding the base64
  overhead of LiveView's JSON serialization for native clients.
  Web clients currently receive base64-encoded output via JSON push.

  Control messages (resize, pane_dead, pane_superseded) use JSON frames.
  """
  use Phoenix.Channel

  alias TmuxRm.PaneStream

  require Logger

  @max_input_size 131_072
  @min_cols 1
  @max_cols 500
  @min_rows 1
  @max_rows 200

  @impl true
  def join("terminal:" <> target_raw, _params, socket) do
    target = parse_target(target_raw)

    case PaneStream.subscribe(target) do
      {:ok, history, pid} ->
        ref = Process.monitor(pid)
        Logger.info("Terminal channel joined: #{target}")

        socket =
          socket
          |> assign(:target, target)
          |> assign(:pane_stream_pid, pid)
          |> assign(:pane_stream_ref, ref)

        {:ok, %{history: Base.encode64(history)}, socket}

      {:error, :not_ready} ->
        Logger.warning("Terminal channel join failed (not ready): #{target}")
        {:error, %{reason: "pane_not_ready"}}

      {:error, reason} ->
        Logger.warning("Terminal channel join failed: #{target}, reason=#{reason}")
        {:error, %{reason: to_string(reason)}}
    end
  end

  # --- Client → Server ---

  @impl true
  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    if byte_size(data) <= @max_input_size do
      PaneStream.send_keys(socket.assigns.target, data)
    end

    {:noreply, socket}
  end

  def handle_in("input", {:binary, data}, socket) do
    if byte_size(data) <= @max_input_size do
      PaneStream.send_keys(socket.assigns.target, data)
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    cols = to_int(cols)
    rows = to_int(rows)

    if cols && rows &&
         cols >= @min_cols && cols <= @max_cols &&
         rows >= @min_rows && rows <= @max_rows do
      PaneStream.resize(socket.assigns.target, cols, rows)
    end

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # --- Server → Client (PubSub) ---

  @impl true
  def handle_info({:pane_output, _target, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info({:pane_dead, _target}, socket) do
    push(socket, "pane_dead", %{})
    {:noreply, socket}
  end

  def handle_info({:pane_reconnected, _target, history}, socket) do
    push(socket, "reconnected", %{data: Base.encode64(history)})
    {:noreply, socket}
  end

  def handle_info({:pane_resized, cols, rows}, socket) do
    push(socket, "resized", %{cols: cols, rows: rows})
    {:noreply, socket}
  end

  def handle_info({:pane_superseded, _old_target, new_target}, socket) do
    push(socket, "superseded", %{new_target: new_target})
    {:noreply, socket}
  end

  # PaneStream crash recovery
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if ref == socket.assigns[:pane_stream_ref] do
      target = socket.assigns.target
      Logger.warning("PaneStream crashed for #{target}, attempting re-subscribe")

      # Small delay to let DynamicSupervisor restart
      Process.sleep(100)

      case PaneStream.subscribe(target) do
        {:ok, history, new_pid} ->
          new_ref = Process.monitor(new_pid)

          push(socket, "reconnected", %{data: Base.encode64(history)})

          socket =
            socket
            |> assign(:pane_stream_pid, new_pid)
            |> assign(:pane_stream_ref, new_ref)

          {:noreply, socket}

        {:error, _reason} ->
          push(socket, "pane_dead", %{})
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if target = socket.assigns[:target] do
      Logger.info("Terminal channel left: #{target}")
      PaneStream.unsubscribe(target)
    end

    :ok
  end

  # "session:window:pane" -> "session:window.pane"
  defp parse_target(raw) do
    case String.split(raw, ":") do
      [session, window, pane] -> "#{session}:#{window}.#{pane}"
      _ -> raw
    end
  end

  defp to_int(val) when is_integer(val), do: val

  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil
end
