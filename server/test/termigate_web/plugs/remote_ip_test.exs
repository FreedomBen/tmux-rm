defmodule TermigateWeb.Plugs.RemoteIpTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias TermigateWeb.Plugs.RemoteIp

  setup do
    prior = Application.get_env(:termigate, :trusted_proxies, [])
    :persistent_term.erase({RemoteIp, :opts})

    on_exit(fn ->
      Application.put_env(:termigate, :trusted_proxies, prior)
      :persistent_term.erase({RemoteIp, :opts})
    end)

    :ok
  end

  test "leaves remote_ip alone when trusted_proxies is empty (default)" do
    Application.put_env(:termigate, :trusted_proxies, [])

    conn = call_with_xff({10, 0, 0, 1}, "8.8.8.8")

    assert conn.remote_ip == {10, 0, 0, 1}
  end

  test "rewrites remote_ip from X-Forwarded-For when proxy chain is trusted" do
    Application.put_env(:termigate, :trusted_proxies, ["10.0.0.0/8"])

    conn = call_with_xff({10, 0, 0, 1}, "8.8.8.8")

    assert conn.remote_ip == {8, 8, 8, 8}
  end

  test "leaves remote_ip alone when X-Forwarded-For header is absent" do
    Application.put_env(:termigate, :trusted_proxies, ["10.0.0.0/8"])

    conn =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> RemoteIp.call(RemoteIp.init([]))

    assert conn.remote_ip == {10, 0, 0, 1}
  end

  defp call_with_xff(peer, xff) do
    :get
    |> conn("/")
    |> Map.put(:remote_ip, peer)
    |> Plug.Conn.put_req_header("x-forwarded-for", xff)
    |> RemoteIp.call(RemoteIp.init([]))
  end
end
