defmodule TermigateWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  channel "terminal:*", TermigateWeb.TerminalChannel
  channel "sessions", TermigateWeb.SessionChannel

  @impl true
  def connect(_params, socket, connect_info) do
    cond do
      not Termigate.Auth.auth_enabled?() ->
        # Fail closed before first-run setup: refuse channel connections until
        # an admin account is created via /setup.
        Logger.info("WebSocket auth rejected: setup not complete, ip=#{extract_ip(connect_info)}")
        :error

      cookie_authenticated?(connect_info) ->
        # Browser path: the signed Plug session cookie carries auth, not a URL
        # token. Per-tab session scoping is enforced by TerminalChannel via a
        # short-lived scope token in join params.
        {:ok, socket}

      token = token_from_headers(connect_info) ->
        # Native/API client path. The header keeps the token out of proxy
        # access logs that record URLs.
        max_age = Termigate.Auth.session_ttl_seconds()
        current_version = Termigate.Auth.auth_version()

        with {:ok, %{auth_version: claim_version}} <-
               Phoenix.Token.verify(TermigateWeb.Endpoint, "api_token", token, max_age: max_age),
             true <- is_binary(claim_version) and claim_version == current_version do
          {:ok, socket}
        else
          _ ->
            Logger.info("WebSocket auth failed from #{extract_ip(connect_info)}")
            :error
        end

      true ->
        Logger.info("WebSocket auth failed from #{extract_ip(connect_info)}")
        :error
    end
  end

  @impl true
  def id(_socket), do: nil

  defp cookie_authenticated?(%{session: session}) when is_map(session) do
    with timestamp when is_integer(timestamp) <- Map.get(session, "authenticated_at"),
         version when is_binary(version) <- Map.get(session, "auth_version"),
         true <- version == Termigate.Auth.auth_version(),
         max_age = Termigate.Auth.session_ttl_seconds(),
         true <- System.system_time(:second) - timestamp <= max_age do
      true
    else
      _ -> false
    end
  end

  defp cookie_authenticated?(_), do: false

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
