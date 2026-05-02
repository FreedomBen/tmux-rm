defmodule TermigateWeb.TerminalChannelTest do
  use TermigateWeb.ChannelCase, async: false

  describe "join" do
    test "returns error when pane not found", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      assert {:error, %{reason: _}} = subscribe_and_join(socket, "terminal:nonexistent:0:0")
    end

    test "parses topic into correct target format", %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)
      # Will fail because no tmux, but should not crash
      result = subscribe_and_join(socket, "terminal:my-session:1:2")
      assert {:error, %{reason: _}} = result
    end

    test "scope token in join params rejects joins to a different session",
         %{cookie_session: session} do
      scope =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "channel_scope", %{session: "alpha"})

      {:ok, socket} = connect_user_socket(session)

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, "terminal:beta:0:0", %{"scope" => scope})
    end

    test "scope token in join params allows joins inside its session",
         %{cookie_session: session} do
      # The join still fails on PaneStream.subscribe (no tmux in tests),
      # but the failure must not be the authz "forbidden" — proving the
      # session-prefix check passed.
      scope =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "channel_scope", %{session: "alpha"})

      {:ok, socket} = connect_user_socket(session)

      assert {:error, %{reason: reason}} =
               subscribe_and_join(socket, "terminal:alpha:0:0", %{"scope" => scope})

      refute reason == "forbidden"
    end

    test "invalid scope token is rejected with invalid_scope",
         %{cookie_session: session} do
      {:ok, socket} = connect_user_socket(session)

      assert {:error, %{reason: "invalid_scope"}} =
               subscribe_and_join(socket, "terminal:alpha:0:0", %{"scope" => "garbage"})
    end

    test "missing scope token leaves the channel unscoped (full access)",
         %{cookie_session: session} do
      # Without a scope token, the channel is not session-pinned. The join
      # still fails on PaneStream.subscribe (no tmux), but not on authz.
      {:ok, socket} = connect_user_socket(session)

      assert {:error, %{reason: reason}} = subscribe_and_join(socket, "terminal:alpha:0:0")
      refute reason == "forbidden"
      refute reason == "invalid_scope"
    end
  end

  describe "handle_in (direct module calls)" do
    test "resize with invalid bounds is a no-op" do
      socket = %Phoenix.Socket{assigns: %{target: "test:0.0"}}

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_in(
                 "resize",
                 %{"cols" => 0, "rows" => 0},
                 socket
               )
    end

    test "resize with out-of-range cols is a no-op" do
      socket = %Phoenix.Socket{assigns: %{target: "test:0.0"}}

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_in(
                 "resize",
                 %{"cols" => 501, "rows" => 40},
                 socket
               )
    end

    test "input exceeding max size is ignored" do
      large_input = String.duplicate("x", 131_073)
      socket = %Phoenix.Socket{assigns: %{target: "test:0.0"}}

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_in(
                 "input",
                 %{"data" => large_input},
                 socket
               )
    end

    test "binary input exceeding max size is ignored" do
      large_input = :binary.copy(<<0>>, 131_073)
      socket = %Phoenix.Socket{assigns: %{target: "test:0.0"}}

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_in(
                 "input",
                 {:binary, large_input},
                 socket
               )
    end

    test "unknown events are handled gracefully" do
      socket = %Phoenix.Socket{assigns: %{target: "test:0.0"}}

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_in("unknown_event", %{}, socket)
    end
  end

  describe "handle_info (direct module calls)" do
    # These test that handle_info returns correct tuples without crashing.
    # We can't test push behavior without a fully joined socket,
    # so we verify the return shape only.

    test "unknown messages are handled gracefully" do
      socket = %Phoenix.Socket{assigns: %{target: "test:0.0"}}

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_info(:some_random_message, socket)
    end

    test "DOWN with non-matching ref is ignored" do
      ref = make_ref()
      other_ref = make_ref()

      socket = %Phoenix.Socket{
        assigns: %{target: "test:0.0", pane_stream_pid: self(), pane_stream_ref: ref}
      }

      assert {:noreply, ^socket} =
               TermigateWeb.TerminalChannel.handle_info(
                 {:DOWN, other_ref, :process, self(), :normal},
                 socket
               )
    end
  end
end
