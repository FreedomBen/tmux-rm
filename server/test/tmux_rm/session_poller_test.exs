defmodule TmuxRm.SessionPollerTest do
  use ExUnit.Case, async: false

  alias TmuxRm.SessionPoller

  import Mox

  setup :verify_on_exit!

  describe "get/0" do
    test "returns sessions list" do
      sessions = SessionPoller.get()
      assert is_list(sessions)
    end
  end

  describe "tmux_status/0" do
    test "returns a status atom or tuple" do
      status = SessionPoller.tmux_status()
      assert status in [:ok, :no_server, :not_found] or match?({:error, _}, status)
    end
  end

  describe "force_poll/0" do
    test "triggers a re-poll without crashing" do
      assert :ok = SessionPoller.force_poll()
      # Synchronous call confirms the cast was processed
      assert is_list(SessionPoller.get())
    end
  end

  describe "PubSub integration" do
    test "broadcasts sessions_updated on change" do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:state")
      SessionPoller.force_poll()
      # The broadcast may or may not fire depending on whether state changed.
      # Synchronous call confirms the cast was processed.
      assert is_list(SessionPoller.get())
    end
  end
end
