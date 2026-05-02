defmodule TermigateWeb.TerminalChannelTest do
  use TermigateWeb.ChannelCase, async: false

  describe "join" do
    test "returns error when pane not found", %{channel_token: token} do
      {:ok, socket} = connect(TermigateWeb.UserSocket, %{"token" => token})
      assert {:error, %{reason: _}} = subscribe_and_join(socket, "terminal:nonexistent:0:0")
    end

    test "parses topic into correct target format", %{channel_token: token} do
      {:ok, socket} = connect(TermigateWeb.UserSocket, %{"token" => token})
      # Will fail because no tmux, but should not crash
      result = subscribe_and_join(socket, "terminal:my-session:1:2")
      assert {:error, %{reason: _}} = result
    end

    test "session-scoped token rejects joins to a different session" do
      scoped_token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "channel", %{session: "alpha"})

      {:ok, socket} = connect(TermigateWeb.UserSocket, %{"token" => scoped_token})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, "terminal:beta:0:0")
    end

    test "session-scoped token allows joins inside its session" do
      # The join still fails on PaneStream.subscribe (no tmux in tests),
      # but the failure must not be the authz "forbidden" — proving the
      # session-prefix check passed.
      scoped_token =
        Phoenix.Token.sign(TermigateWeb.Endpoint, "channel", %{session: "alpha"})

      {:ok, socket} = connect(TermigateWeb.UserSocket, %{"token" => scoped_token})

      assert {:error, %{reason: reason}} =
               subscribe_and_join(socket, "terminal:alpha:0:0")

      refute reason == "forbidden"
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
