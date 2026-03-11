defmodule TmuxRmWeb.TerminalChannelTest do
  use TmuxRmWeb.ChannelCase, async: false

  describe "join" do
    test "returns error when pane not found" do
      {:ok, socket} = connect(TmuxRmWeb.UserSocket, %{})
      # This will fail because no tmux pane exists in test
      assert {:error, %{reason: _}} = subscribe_and_join(socket, "terminal:nonexistent:0:0")
    end
  end
end
