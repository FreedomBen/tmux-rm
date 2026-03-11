defmodule TmuxRmWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  channel "terminal:*", TmuxRmWeb.TerminalChannel
  channel "sessions", TmuxRmWeb.SessionChannel

  @impl true
  def connect(params, socket, connect_info) do
    if TmuxRm.Auth.auth_enabled?() do
      max_age = TmuxRm.Auth.session_ttl_seconds()

      case Phoenix.Token.verify(TmuxRmWeb.Endpoint, "channel", params["token"], max_age: max_age) do
        {:ok, _data} ->
          {:ok, socket}

        {:error, _reason} ->
          # Also try api_token for API clients
          case Phoenix.Token.verify(TmuxRmWeb.Endpoint, "api_token", params["token"],
                 max_age: max_age
               ) do
            {:ok, _data} ->
              {:ok, socket}

            {:error, _} ->
              ip = extract_ip(connect_info)
              Logger.info("WebSocket auth failed from #{ip}")
              :error
          end
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def id(_socket), do: nil

  defp extract_ip(%{peer_data: %{address: addr}}) do
    addr |> :inet.ntoa() |> to_string()
  end

  defp extract_ip(_), do: "unknown"
end
