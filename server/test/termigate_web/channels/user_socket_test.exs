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
end
