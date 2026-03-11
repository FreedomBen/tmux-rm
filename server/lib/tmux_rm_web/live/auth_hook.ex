defmodule TmuxRmWeb.AuthHook do
  @moduledoc "LiveView on_mount hook that checks authentication on every mount."
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    if TmuxRm.Auth.auth_enabled?() do
      case session["authenticated_at"] do
        nil ->
          {:halt, socket |> put_flash(:error, "Please log in.") |> redirect(to: "/login")}

        timestamp ->
          ttl_days = Application.get_env(:tmux_rm, :auth_session_ttl_days, 30)

          if ttl_days && session_expired?(timestamp, ttl_days) do
            {:halt,
             socket
             |> put_flash(:error, "Session expired. Please log in again.")
             |> redirect(to: "/login")}
          else
            {:cont, assign(socket, :authenticated_at, timestamp)}
          end
      end
    else
      {:cont, socket}
    end
  end

  defp session_expired?(timestamp, ttl_days) when is_integer(timestamp) do
    expiry = timestamp + ttl_days * 86_400
    System.system_time(:second) > expiry
  end

  defp session_expired?(_, _), do: true
end
