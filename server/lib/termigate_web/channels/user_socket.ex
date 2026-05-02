defmodule TermigateWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  channel "terminal:*", TermigateWeb.TerminalChannel
  channel "sessions", TermigateWeb.SessionChannel

  @impl true
  def connect(params, socket, connect_info) do
    if Termigate.Auth.auth_enabled?() do
      max_age = Termigate.Auth.session_ttl_seconds()
      # Prefer the header so the token does not appear in proxy access logs;
      # fall back to URL params for the in-browser JS client.
      token = token_from_headers(connect_info) || params["token"]

      case Phoenix.Token.verify(TermigateWeb.Endpoint, "channel", token, max_age: max_age) do
        {:ok, _data} ->
          {:ok, socket}

        {:error, _reason} ->
          # Also try api_token for API clients
          case Phoenix.Token.verify(TermigateWeb.Endpoint, "api_token", token, max_age: max_age) do
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

  defp token_from_headers(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-auth-token", value} -> value
      _ -> nil
    end)
  end

  defp token_from_headers(_), do: nil

  defp extract_ip(%{peer_data: %{address: addr}}) do
    addr |> :inet.ntoa() |> to_string()
  end

  defp extract_ip(_), do: "unknown"
end
