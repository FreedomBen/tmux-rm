defmodule TermigateWeb.Plugs.RequireSetupAccessTest do
  use TermigateWeb.ConnCase, async: false

  alias TermigateWeb.Plugs.RequireSetupAccess

  # Tests below directly drive Auth state and Setup token; skip ConnCase auto-auth.
  @moduletag :skip_auth

  setup do
    Application.delete_env(:termigate, :auth_token)
    Termigate.Setup.replace("test-setup-token")
    on_exit(fn -> Termigate.Setup.replace(nil) end)
    :ok
  end

  defp build(remote_ip, query) do
    Phoenix.ConnTest.build_conn(:get, "/setup?" <> query)
    |> Map.put(:remote_ip, remote_ip)
  end

  describe "call/2 with no admin yet" do
    test "passes when loopback IPv4 + valid token" do
      conn = build({127, 0, 0, 1}, "token=test-setup-token") |> RequireSetupAccess.call([])
      refute conn.halted
    end

    test "passes when loopback IPv6 + valid token" do
      conn =
        build({0, 0, 0, 0, 0, 0, 0, 1}, "token=test-setup-token")
        |> RequireSetupAccess.call([])

      refute conn.halted
    end

    test "passes for any 127.0.0.0/8 address" do
      conn = build({127, 5, 6, 7}, "token=test-setup-token") |> RequireSetupAccess.call([])
      refute conn.halted
    end

    test "404s from non-loopback IP even with valid token" do
      conn = build({10, 0, 0, 5}, "token=test-setup-token") |> RequireSetupAccess.call([])
      assert conn.halted
      assert conn.status == 404
    end

    test "404s with missing token" do
      conn = build({127, 0, 0, 1}, "") |> RequireSetupAccess.call([])
      assert conn.halted
      assert conn.status == 404
    end

    test "404s with wrong token" do
      conn = build({127, 0, 0, 1}, "token=wrong") |> RequireSetupAccess.call([])
      assert conn.halted
      assert conn.status == 404
    end

    test "404s after the token has been consumed" do
      Termigate.Setup.consume()
      conn = build({127, 0, 0, 1}, "token=test-setup-token") |> RequireSetupAccess.call([])
      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "call/2 with admin already configured" do
    setup do
      Application.put_env(:termigate, :auth_token, "test-token")
      :ok
    end

    test "passes through (LiveView will redirect to /login)" do
      conn = build({203, 0, 113, 5}, "") |> RequireSetupAccess.call([])
      refute conn.halted
    end
  end
end
