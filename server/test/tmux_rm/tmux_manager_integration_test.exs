defmodule TmuxRm.TmuxManagerIntegrationTest do
  use ExUnit.Case, async: false

  import TmuxRm.TmuxHelpers

  @moduletag :tmux

  setup do
    # Override command runner to use real tmux
    original = Application.get_env(:tmux_rm, :command_runner)
    Application.put_env(:tmux_rm, :command_runner, TmuxRm.Tmux.CommandRunner)
    on_exit(fn -> Application.put_env(:tmux_rm, :command_runner, original) end)
    :ok
  end

  describe "list_sessions/0 integration" do
    setup :setup_tmux

    test "returns real sessions", %{session: session} do
      {:ok, sessions} = TmuxRm.TmuxManager.list_sessions()
      names = Enum.map(sessions, & &1.name)
      assert session in names
    end
  end

  describe "create_session/1 integration" do
    test "creates and lists a new session" do
      name = "integ-test-#{:rand.uniform(100_000)}"
      on_exit(fn -> destroy_test_session(name) end)

      assert :ok = TmuxRm.TmuxManager.create_session(name)
      {:ok, sessions} = TmuxRm.TmuxManager.list_sessions()
      names = Enum.map(sessions, & &1.name)
      assert name in names
    end
  end

  describe "kill_session/1 integration" do
    setup :setup_tmux

    test "kills an existing session", %{session: session} do
      assert :ok = TmuxRm.TmuxManager.kill_session(session)
      {:ok, sessions} = TmuxRm.TmuxManager.list_sessions()
      names = Enum.map(sessions, & &1.name)
      refute session in names
    end
  end

  describe "rename_session/2 integration" do
    setup :setup_tmux

    test "renames a session", %{session: session} do
      new_name = "renamed-#{:rand.uniform(100_000)}"
      on_exit(fn -> destroy_test_session(new_name) end)

      assert :ok = TmuxRm.TmuxManager.rename_session(session, new_name)
      {:ok, sessions} = TmuxRm.TmuxManager.list_sessions()
      names = Enum.map(sessions, & &1.name)
      assert new_name in names
      refute session in names
    end
  end
end
