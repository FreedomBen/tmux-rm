defmodule TmuxRmWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel for binary terminal I/O.

  Handles keyboard input and terminal output as binary frames,
  avoiding the base64 overhead of LiveView's JSON serialization.
  """
  use Phoenix.Channel

  alias TmuxRm.PaneStream

  require Logger

  @impl true
  def join("terminal:" <> target_raw, _params, socket) do
    # Convert channel topic format back to tmux target: "session:window:pane" -> "session:window.pane"
    target = parse_target(target_raw)

    case PaneStream.subscribe(target) do
      {:ok, history, _pid} ->
        socket =
          socket
          |> assign(:target, target)
          |> assign(:pane_stream_pid, nil)

        # Send history as base64 in the join reply (JSON text frame)
        {:ok, %{history: Base.encode64(history)}, socket}

      {:error, :not_ready} ->
        {:error, %{reason: "pane_not_ready"}}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    case PaneStream.send_keys(socket.assigns.target, data) do
      :ok -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_in("input", {:binary, data}, socket) do
    case PaneStream.send_keys(socket.assigns.target, data) do
      :ok -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

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

  @impl true
  def terminate(_reason, socket) do
    if target = socket.assigns[:target] do
      PaneStream.unsubscribe(target)
    end

    :ok
  end

  # "session:window:pane" -> "session:window.pane"
  defp parse_target(raw) do
    case String.split(raw, ":") do
      [session, window, pane] -> "#{session}:#{window}.#{pane}"
      # Fallback: use as-is
      _ -> raw
    end
  end
end
