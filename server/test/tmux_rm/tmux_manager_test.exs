defmodule TmuxRm.TmuxManagerTest do
  use ExUnit.Case, async: false

  import Mox

  alias TmuxRm.TmuxManager
  alias TmuxRm.Tmux.{Session, Pane}

  setup do
    # Swap in MockCommandRunner for these tests
    original = Application.get_env(:tmux_rm, :command_runner)
    Application.put_env(:tmux_rm, :command_runner, TmuxRm.MockCommandRunner)
    on_exit(fn -> Application.put_env(:tmux_rm, :command_runner, original) end)
    :ok
  end

  setup :verify_on_exit!

  describe "list_sessions/0" do
    test "parses session list output" do
      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert List.last(args) =~ "session_name"
        {:ok, "dev\t3\t1700000000\t1\nwork\t1\t1700000100\t0"}
      end)

      assert {:ok, sessions} = TmuxManager.list_sessions()
      assert length(sessions) == 2

      [dev, work] = sessions
      assert %Session{name: "dev", windows: 3, attached?: true} = dev
      assert %Session{name: "work", windows: 1, attached?: false} = work
      assert %DateTime{} = dev.created
    end

    test "returns empty list when no server running" do
      expect(TmuxRm.MockCommandRunner, :run, fn _args ->
        {:error, {"no server running on /tmp/tmux-1000/default", 1}}
      end)

      assert {:ok, []} = TmuxManager.list_sessions()
    end

    test "returns error when tmux not found" do
      expect(TmuxRm.MockCommandRunner, :run, fn _args ->
        {:error, {"executable file not found in $PATH", 127}}
      end)

      assert {:error, :tmux_not_found} = TmuxManager.list_sessions()
    end

    test "handles single session" do
      expect(TmuxRm.MockCommandRunner, :run, fn _args ->
        {:ok, "solo\t1\t1700000000\t0"}
      end)

      assert {:ok, [%Session{name: "solo"}]} = TmuxManager.list_sessions()
    end
  end

  describe "list_panes/1" do
    test "parses pane list grouped by window" do
      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "-s" in args
        assert "-t" in args

        {:ok,
         "dev\t0\t0\t120\t40\tbash\t%0\ndev\t0\t1\t60\t40\tvim\t%1\ndev\t1\t0\t120\t40\thtop\t%2"}
      end)

      assert {:ok, panes} = TmuxManager.list_panes("dev")
      assert map_size(panes) == 2
      assert length(panes[0]) == 2
      assert length(panes[1]) == 1

      [p0, p1] = panes[0]

      assert %Pane{session_name: "dev", window_index: 0, index: 0, command: "bash", pane_id: "%0"} =
               p0

      assert %Pane{window_index: 0, index: 1, command: "vim", pane_id: "%1"} = p1
    end

    test "returns error for nonexistent session" do
      expect(TmuxRm.MockCommandRunner, :run, fn _args ->
        {:error, {"can't find session: nope", 1}}
      end)

      assert {:error, :session_not_found} = TmuxManager.list_panes("nope")
    end
  end

  describe "valid_session_name?/1" do
    test "accepts valid names" do
      assert TmuxManager.valid_session_name?("good-name_1")
      assert TmuxManager.valid_session_name?("dev")
      assert TmuxManager.valid_session_name?("MySession")
      assert TmuxManager.valid_session_name?("test_123")
    end

    test "rejects invalid names" do
      refute TmuxManager.valid_session_name?("bad:name")
      refute TmuxManager.valid_session_name?("bad.name")
      refute TmuxManager.valid_session_name?("bad name")
      refute TmuxManager.valid_session_name?("bad/name")
      refute TmuxManager.valid_session_name?("")
      refute TmuxManager.valid_session_name?(nil)
    end
  end

  describe "create_session/1" do
    test "creates session and broadcasts change" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:mutations")

      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "new-session" in args
        assert "-s" in args
        assert "test-session" in args
        {:ok, ""}
      end)

      assert {:ok, %{name: "test-session"}} = TmuxManager.create_session("test-session")
      assert_receive {:sessions_changed}
    end

    test "rejects invalid session name" do
      assert {:error, :invalid_name} = TmuxManager.create_session("bad:name")
    end

    test "returns error on tmux failure" do
      expect(TmuxRm.MockCommandRunner, :run, fn _args ->
        {:error, {"duplicate session: test", 1}}
      end)

      assert {:error, "duplicate session: test"} = TmuxManager.create_session("test")
    end
  end

  describe "kill_session/1" do
    test "kills session and broadcasts change" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:mutations")

      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "kill-session" in args
        {:ok, ""}
      end)

      assert :ok = TmuxManager.kill_session("test")
      assert_receive {:sessions_changed}
    end
  end

  describe "session_exists?/1" do
    test "returns true when session exists" do
      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "has-session" in args
        {:ok, ""}
      end)

      assert TmuxManager.session_exists?("test")
    end

    test "returns false when session does not exist" do
      expect(TmuxRm.MockCommandRunner, :run, fn _args ->
        {:error, {"can't find session: nope", 1}}
      end)

      refute TmuxManager.session_exists?("nope")
    end
  end

  describe "rename_session/2" do
    test "renames session and broadcasts" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:mutations")

      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "rename-session" in args
        {:ok, ""}
      end)

      assert :ok = TmuxManager.rename_session("old", "new-name")
      assert_receive {:sessions_changed}
    end

    test "rejects invalid new name" do
      assert {:error, :invalid_name} = TmuxManager.rename_session("old", "bad.name")
    end
  end

  describe "create_window/1" do
    test "creates window and broadcasts" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:mutations")

      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "new-window" in args
        {:ok, ""}
      end)

      assert :ok = TmuxManager.create_window("test")
      assert_receive {:sessions_changed}
    end
  end

  describe "split_pane/2" do
    test "splits pane horizontally by default" do
      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "-h" in args
        {:ok, ""}
      end)

      assert {:ok, _} = TmuxManager.split_pane("test:0.0")
    end

    test "splits pane vertically" do
      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "-v" in args
        {:ok, ""}
      end)

      assert {:ok, _} = TmuxManager.split_pane("test:0.0", :vertical)
    end
  end

  describe "kill_pane/1" do
    test "kills pane and broadcasts" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:mutations")

      expect(TmuxRm.MockCommandRunner, :run, fn args ->
        assert "kill-pane" in args
        {:ok, ""}
      end)

      assert :ok = TmuxManager.kill_pane("test:0.0")
      assert_receive {:sessions_changed}
    end
  end
end
