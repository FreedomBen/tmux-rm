defmodule TmuxRmWeb.SessionChannelTest do
  use TmuxRmWeb.ChannelCase, async: false

  describe "join" do
    test "returns current session list on join" do
      {:ok, socket} = connect(TmuxRmWeb.UserSocket, %{})
      {:ok, reply, _socket} = subscribe_and_join(socket, "sessions")

      assert %{sessions: sessions} = reply
      assert is_list(sessions)
    end
  end

  describe "handle_info" do
    test "sessions_updated pushes when list changes" do
      {:ok, socket} = connect(TmuxRmWeb.UserSocket, %{})
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      # Simulate a session update via PubSub
      new_sessions = [
        %TmuxRm.Tmux.Session{
          name: "test-session",
          windows: 1,
          created: 1_710_000_000,
          attached?: false
        }
      ]

      send(socket.channel_pid, {:sessions_updated, new_sessions})

      assert_push "sessions_updated", %{sessions: sessions}
      assert [%{name: "test-session", windows: 1}] = sessions
    end

    test "sessions_updated does not push when list unchanged" do
      {:ok, socket} = connect(TmuxRmWeb.UserSocket, %{})
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      # Send the same empty list (matching initial state)
      send(socket.channel_pid, {:sessions_updated, []})

      refute_push "sessions_updated", _
    end

    test "tmux_status_changed pushes status" do
      {:ok, socket} = connect(TmuxRmWeb.UserSocket, %{})
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      send(socket.channel_pid, {:tmux_status_changed, :not_found})

      assert_push "tmux_status", %{status: "not_found"}
    end

    test "tmux_status_changed handles error tuple" do
      {:ok, socket} = connect(TmuxRmWeb.UserSocket, %{})
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      send(socket.channel_pid, {:tmux_status_changed, {:error, "connection refused"}})

      assert_push "tmux_status", %{status: "error: connection refused"}
    end
  end
end
