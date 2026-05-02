defmodule TermigateWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel for binary terminal I/O.

  Handles keyboard input and terminal output, avoiding the base64
  overhead of LiveView's JSON serialization for native clients.
  Web clients currently receive base64-encoded output via JSON push.

  Control messages (resize, pane_dead, pane_superseded) use JSON frames.
  """
  use Phoenix.Channel

  alias Termigate.PaneStream

  require Logger

  @max_input_size 131_072
  @min_cols 1
  @max_cols 500
  @min_rows 1
  @max_rows 200
  @scope_max_age 300

  @impl true
  def join("terminal:" <> target_raw, params, socket) do
    target = parse_target(target_raw)

    with {:ok, socket} <- apply_scope(socket, params),
         :ok <- authorize_target(socket, target) do
      do_join(target, params, socket)
    end
  end

  defp do_join(target, params, socket) do
    case PaneStream.subscribe(target) do
      {:ok, history, pid} ->
        ref = Process.monitor(pid)
        Logger.info("Terminal channel joined: #{target}")

        # Resize pane to client dimensions before sending history,
        # so captured content matches the browser terminal size.
        history = maybe_resize_and_recapture(target, params, history)

        socket =
          socket
          |> assign(:target, target)
          |> assign(:pane_stream_pid, pid)
          |> assign(:pane_stream_ref, ref)
          |> assign(:pane_dead, false)

        reply = %{history: Base.encode64(history)}

        reply =
          case PaneStream.dimensions(target) do
            {:ok, {cols, rows}} -> Map.merge(reply, %{cols: cols, rows: rows})
            _ -> reply
          end

        {:ok, reply, socket}

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
    {:noreply, assign(socket, :pane_dead, true)}
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

      # If we already know the pane is dead, don't attempt re-subscribe
      if socket.assigns[:pane_dead] do
        {:noreply, socket}
      else
        Logger.warning("PaneStream crashed for #{target}, attempting re-subscribe")

        # Unsubscribe first to prevent duplicate PubSub subscriptions
        Phoenix.PubSub.unsubscribe(Termigate.PubSub, "pane:#{target}")

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
            {:noreply, assign(socket, :pane_dead, true)}
        end
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

  defp maybe_resize_and_recapture(target, %{"cols" => cols, "rows" => rows}, old_history) do
    cols = to_int(cols)
    rows = to_int(rows)

    if cols && rows &&
         cols >= @min_cols && cols <= @max_cols &&
         rows >= @min_rows && rows <= @max_rows do
      Logger.info("Resizing pane on join: #{target} to #{cols}x#{rows}")

      case PaneStream.resize_and_capture(target, cols, rows) do
        {:ok, history} ->
          Logger.info("resize_and_capture succeeded, #{byte_size(history)} bytes")
          history

        {:error, reason} ->
          Logger.warning("resize_and_capture failed: #{inspect(reason)}")
          old_history
      end
    else
      Logger.warning("Invalid join dimensions: cols=#{inspect(cols)} rows=#{inspect(rows)}")
      old_history
    end
  end

  defp maybe_resize_and_recapture(_target, params, history) do
    Logger.debug("No cols/rows in join params: #{inspect(Map.keys(params))}")
    history
  end

  # "session:window:pane" -> "session:window.pane"
  defp parse_target(raw) do
    case String.split(raw, ":") do
      [session, window, pane] -> "#{session}:#{window}.#{pane}"
      _ -> raw
    end
  end

  # Browser channels carry a short-lived scope token in join params; verifying
  # it pins the channel to a single tmux session as defense-in-depth. Native
  # API clients that authenticate with `x-auth-token` send no scope token and
  # are already trusted for full access.
  defp apply_scope(socket, params) do
    case params["scope"] do
      token when is_binary(token) and token != "" ->
        case Phoenix.Token.verify(TermigateWeb.Endpoint, "channel_scope", token,
               max_age: @scope_max_age
             ) do
          {:ok, %{session: session}} when is_binary(session) ->
            {:ok, assign(socket, :channel_session, session)}

          {:error, _reason} ->
            Logger.warning("Terminal channel join rejected: invalid scope token")
            {:error, %{reason: "invalid_scope"}}
        end

      _ ->
        {:ok, socket}
    end
  end

  defp authorize_target(socket, target) do
    case socket.assigns[:channel_session] do
      nil ->
        :ok

      session ->
        case String.split(target, ":", parts: 2) do
          [^session, _rest] ->
            :ok

          _ ->
            Logger.warning(
              "Terminal channel join rejected: target #{target} outside scoped session #{session}"
            )

            {:error, %{reason: "forbidden"}}
        end
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
