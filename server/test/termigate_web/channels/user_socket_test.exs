defmodule TermigateWeb.UserSocketTest do
  use TermigateWeb.ChannelCase, async: false

  describe "connect/3" do
    test "authenticates via x-auth-token header", %{channel_token: token} do
      assert {:ok, _socket} =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: [{"x-auth-token", token}]}
               )
    end

    test "authenticates via URL params for back-compat", %{channel_token: token} do
      assert {:ok, _socket} = connect(TermigateWeb.UserSocket, %{"token" => token})
    end

    test "header takes precedence over an invalid URL param", %{channel_token: token} do
      assert {:ok, _socket} =
               connect(
                 TermigateWeb.UserSocket,
                 %{"token" => "garbage"},
                 connect_info: %{x_headers: [{"x-auth-token", token}]}
               )
    end

    test "rejects when no token is present anywhere" do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{},
                 connect_info: %{x_headers: []}
               )
    end

    test "rejects when both header and param are invalid" do
      assert :error =
               connect(
                 TermigateWeb.UserSocket,
                 %{"token" => "garbage"},
                 connect_info: %{x_headers: [{"x-auth-token", "also-garbage"}]}
               )
    end
  end
end
