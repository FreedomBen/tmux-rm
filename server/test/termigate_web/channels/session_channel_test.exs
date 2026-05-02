defmodule TermigateWeb.SessionChannelTest do
  use TermigateWeb.ChannelCase, async: false

  describe "join" do
    test "returns current session list on join", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      {:ok, reply, _socket} = subscribe_and_join(socket, "sessions")

      assert %{sessions: sessions} = reply
      assert is_list(sessions)
    end
  end

  describe "handle_info" do
    test "sessions_updated pushes when list changes", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      # Simulate a session update via PubSub
      new_sessions = [
        %Termigate.Tmux.Session{
          name: "test-session",
          windows: 1,
          created: DateTime.from_unix!(1_710_000_000),
          attached?: false
        }
      ]

      send(socket.channel_pid, {:sessions_updated, new_sessions})

      assert_push "sessions_updated", %{sessions: sessions}
      assert [%{name: "test-session", windows: 1}] = sessions
    end

    test "sessions_updated does not push when list unchanged", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      # Concurrent tests can broadcast on "sessions:state" via SessionPoller,
      # which mutates the channel's last_sessions assignment. Sync the channel
      # to drain in-flight messages, then echo its current state back so the
      # comparison is deterministically "unchanged".
      current = :sys.get_state(socket.channel_pid).assigns.last_sessions
      send(socket.channel_pid, {:sessions_updated, current})

      refute_push "sessions_updated", _
    end

    test "tmux_status_changed pushes status", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      send(socket.channel_pid, {:tmux_status_changed, :not_found})

      assert_push "tmux_status", %{status: "not_found"}
    end

    test "tmux_status_changed handles error tuple", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      {:ok, _reply, socket} = subscribe_and_join(socket, "sessions")

      send(socket.channel_pid, {:tmux_status_changed, {:error, "connection refused"}})

      assert_push "tmux_status", %{status: "error: connection refused"}
    end
  end
end
