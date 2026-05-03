defmodule TermigateWeb.UserSocketTest do
  use TermigateWeb.ChannelCase, async: false

  describe "connect/3" do
    test "authenticates via cookie session", %{cookie_session: session} do
      assert {:ok, _socket} =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{session: session}
               )
    end

    test "rejects an expired cookie session" do
      ttl = Termigate.Auth.session_ttl_seconds()
      stale = %{"authenticated_at" => System.system_time(:second) - ttl - 60}

      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{session: stale}
               )
    end

    test "authenticates via x-auth-token header", %{api_token: token} do
      assert {:ok, _socket} =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: [{"x-auth-token", token}]}
               )
    end

    test "rejects an invalid header token" do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: [{"x-auth-token", "garbage"}]}
               )
    end

    test "ignores URL token params (no longer accepted)", %{api_token: token} do
      # The browser flow no longer authenticates via URL — even a valid token
      # passed as a URL param is rejected when no cookie or header is present.
      assert :error = connect(TermigateWeb.UserSocket, %{"token" => token})
    end

    test "rejects when no auth is provided" do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: []}
               )
    end

    test "does not assign :channel_session at the socket level", %{api_token: token} do
      # Per-tab session scoping moved to TerminalChannel.join via a scope
      # token in join params; the socket itself stays unscoped.
      assert {:ok, socket} =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: [{"x-auth-token", token}]}
               )

      refute Map.has_key?(socket.assigns, :channel_session)
    end
  end

  describe "connect/3 before first-run setup" do
    setup do
      original = Application.get_env(:termigate, :auth_token)
      Application.delete_env(:termigate, :auth_token)
      on_exit(fn -> Application.put_env(:termigate, :auth_token, original) end)
      :ok
    end

    test "fails closed on cookie path", %{cookie_session: session} do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{session: session}
               )
    end

    test "fails closed on header path", %{api_token: token} do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: [{"x-auth-token", token}]}
               )
    end

    test "fails closed with no auth at all" do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: []}
               )
    end
  end

  # End-to-end exercise of the cookie + CSRF path that the older
  # `connect_info: %{session: session}` tests skip. The other tests pass
  # an already-decoded session map straight in, bypassing the cookie
  # decode and CSRF check that Phoenix.Socket.Transport runs at WS upgrade
  # time. These tests run a real signed cookie through the actual transport
  # entry point (`Phoenix.Socket.Transport.connect_info/4`) so a regression
  # of the F-05 class — where the upgrade carries the cookie but no
  # `_csrf_token`, and Phoenix silently drops the session before
  # UserSocket.connect/3 ever sees it — fails this test instead of
  # only showing up in a manual server drive.
  describe "ws upgrade with signed cookie + CSRF query (F-05 regression guard)" do
    setup do
      masked = Plug.CSRFProtection.get_csrf_token()
      unmasked = Plug.CSRFProtection.dump_state()

      session_data = %{
        "authenticated_at" => System.system_time(:second),
        "auth_version" => Termigate.Auth.auth_version(),
        "_csrf_token" => unmasked
      }

      config = TermigateWeb.Endpoint.runtime_session_options()
      cookie_key = Keyword.fetch!(config, :key)
      store = Plug.Session.Store.get(Keyword.fetch!(config, :store))
      init = store.init(Keyword.drop(config, [:store, :key]))

      encode_conn =
        Phoenix.ConnTest.build_conn(:get, "/")
        |> Map.put(:secret_key_base, TermigateWeb.Endpoint.config(:secret_key_base))

      cookie_value = store.put(encode_conn, nil, session_data, init)

      session_init = {cookie_key, store, {"_csrf_token", init}}

      {:ok,
       masked: masked,
       cookie_key: cookie_key,
       cookie_value: cookie_value,
       session_init: session_init}
    end

    test "succeeds when both cookie and _csrf_token query param are present", %{
      masked: masked,
      cookie_key: cookie_key,
      cookie_value: cookie_value,
      session_init: session_init
    } do
      ws_conn =
        Phoenix.ConnTest.build_conn(
          :get,
          "/socket/websocket?_csrf_token=#{URI.encode_www_form(masked)}"
        )
        |> Plug.Conn.put_req_header("cookie", "#{cookie_key}=#{cookie_value}")
        |> Plug.Conn.fetch_query_params()

      connect_info =
        Phoenix.Socket.Transport.connect_info(
          ws_conn,
          TermigateWeb.Endpoint,
          [{:session, session_init}]
        )

      assert is_map(connect_info[:session]),
             "expected the transport to decode the session, got: #{inspect(connect_info[:session])}"

      assert {:ok, _socket} =
               connect(TermigateWeb.UserSocket, %{}, connect_info: connect_info)
    end

    test "rejects when the cookie is sent but _csrf_token query param is missing", %{
      cookie_key: cookie_key,
      cookie_value: cookie_value,
      session_init: session_init
    } do
      ws_conn =
        Phoenix.ConnTest.build_conn(:get, "/socket/websocket")
        |> Plug.Conn.put_req_header("cookie", "#{cookie_key}=#{cookie_value}")
        |> Plug.Conn.fetch_query_params()

      connect_info =
        Phoenix.Socket.Transport.connect_info(
          ws_conn,
          TermigateWeb.Endpoint,
          [{:session, session_init}]
        )

      # The CSRF check inside the transport drops the session entirely;
      # UserSocket only sees `connect_info[:session] == nil` and falls
      # through to the catch-all :error branch — same outcome the user
      # saw as a 403 in the F-05 drive.
      assert connect_info[:session] == nil

      assert :error =
               connect(TermigateWeb.UserSocket, %{}, connect_info: connect_info)
    end

    test "rejects when _csrf_token query param does not match the session state", %{
      cookie_key: cookie_key,
      cookie_value: cookie_value,
      session_init: session_init
    } do
      ws_conn =
        Phoenix.ConnTest.build_conn(:get, "/socket/websocket?_csrf_token=garbage")
        |> Plug.Conn.put_req_header("cookie", "#{cookie_key}=#{cookie_value}")
        |> Plug.Conn.fetch_query_params()

      connect_info =
        Phoenix.Socket.Transport.connect_info(
          ws_conn,
          TermigateWeb.Endpoint,
          [{:session, session_init}]
        )

      assert connect_info[:session] == nil

      assert :error =
               connect(TermigateWeb.UserSocket, %{}, connect_info: connect_info)
    end
  end
end
