defmodule TermigateWeb.AuthHook do
  @moduledoc """
  LiveView on_mount hook that enforces authentication.

  Verifies the session at mount, attaches `handle_event` / `handle_info` hooks
  that recheck the TTL on every interaction, and schedules a periodic tick so
  idle sockets are also disconnected once the configured TTL passes.

  TTL is read from `Termigate.Auth.session_ttl_seconds/0` to stay in sync
  with the HTTP `RequireAuth` plug.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  # How often (ms) idle sockets recheck their TTL.
  @periodic_check_ms 60_000

  # Minimum interval between TTL rechecks driven by handle_event/handle_info,
  # to avoid re-reading the auth config on bursts of user input.
  @recheck_throttle_seconds 5

  def on_mount(:default, _params, session, socket) do
    if Termigate.Auth.auth_enabled?() do
      case session["authenticated_at"] do
        timestamp when is_integer(timestamp) ->
          if session_expired?(timestamp) do
            {:halt, redirect_to_login(socket, "Session expired. Please log in again.")}
          else
            socket =
              socket
              |> assign(:authenticated_at, timestamp)
              |> assign(:auth_last_check, System.system_time(:second))
              |> attach_hook(:auth_ttl_event, :handle_event, &recheck_event/3)
              |> attach_hook(:auth_ttl_info, :handle_info, &recheck_info/2)

            if connected?(socket), do: schedule_periodic_check()

            {:cont, socket}
          end

        _ ->
          {:halt, redirect_to_login(socket, "Please log in.")}
      end
    else
      {:cont, socket}
    end
  end

  defp recheck_event(_event, _params, socket) do
    case throttled_recheck(socket) do
      {:ok, socket} -> {:cont, socket}
      {:expired, socket} -> {:halt, socket}
    end
  end

  defp recheck_info(:__auth_ttl_check__, socket) do
    if connected?(socket), do: schedule_periodic_check()

    case do_recheck(socket) do
      {:ok, socket} -> {:halt, socket}
      {:expired, socket} -> {:halt, socket}
    end
  end

  defp recheck_info(_msg, socket) do
    case throttled_recheck(socket) do
      {:ok, socket} -> {:cont, socket}
      {:expired, socket} -> {:halt, socket}
    end
  end

  defp throttled_recheck(socket) do
    now = System.system_time(:second)
    last = socket.assigns[:auth_last_check] || 0

    if now - last < @recheck_throttle_seconds do
      {:ok, socket}
    else
      do_recheck(socket)
    end
  end

  defp do_recheck(socket) do
    timestamp = socket.assigns[:authenticated_at]

    cond do
      is_nil(timestamp) ->
        {:ok, socket}

      session_expired?(timestamp) ->
        {:expired, redirect_to_login(socket, "Session expired. Please log in again.")}

      true ->
        {:ok, assign(socket, :auth_last_check, System.system_time(:second))}
    end
  end

  defp session_expired?(timestamp) when is_integer(timestamp) do
    System.system_time(:second) - timestamp > Termigate.Auth.session_ttl_seconds()
  end

  defp session_expired?(_), do: true

  defp schedule_periodic_check do
    Process.send_after(self(), :__auth_ttl_check__, @periodic_check_ms)
  end

  defp redirect_to_login(socket, msg) do
    socket
    |> put_flash(:error, msg)
    |> redirect(to: "/login")
  end
end
