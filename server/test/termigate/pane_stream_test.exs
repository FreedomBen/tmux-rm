defmodule Termigate.PaneStreamTest do
  use ExUnit.Case

  import Termigate.TmuxHelpers

  alias Termigate.PaneStream

  @moduletag :tmux

  setup do
    # Use real CommandRunner for integration tests
    original = Application.get_env(:termigate, :command_runner)
    Application.put_env(:termigate, :command_runner, Termigate.Tmux.CommandRunner)

    on_exit(fn ->
      Application.put_env(:termigate, :command_runner, original)
    end)

    :ok
  end

  setup _context do
    name = create_test_session()

    on_exit(fn ->
      # Stop any PaneStream BEFORE destroying the tmux session
      target = "#{name}:0.0"
      stop_pane_stream(target)
      destroy_test_session(name)
    end)

    %{session: name}
  end

  defp stop_pane_stream(target) do
    case Registry.lookup(Termigate.PaneRegistry, {:pane, target}) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal, 5000)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5000 -> :ok
        end

      [] ->
        :ok
    end
  end

  describe "subscribe/1" do
    test "subscribes to a pane and receives history", %{session: session} do
      target = "#{session}:0.0"

      assert {:ok, history, pid} = PaneStream.subscribe(target)
      assert is_binary(history)
      assert is_pid(pid)
    end

    test "multiple viewers share a single PaneStream", %{session: session} do
      target = "#{session}:0.0"

      assert {:ok, _history1, pid1} = PaneStream.subscribe(target)

      # Subscribe from another process
      task =
        Task.async(fn ->
          {:ok, _history, pid} = PaneStream.subscribe(target)
          pid
        end)

      pid2 = Task.await(task)

      # Same PaneStream process
      assert pid1 == pid2
    end
  end

  describe "send_keys/2" do
    test "sends input to the pane", %{session: session} do
      target = "#{session}:0.0"

      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Send some text — actual newline byte
      assert :ok = PaneStream.send_keys(target, "echo hello\n")
    end

    test "returns error for nonexistent pane" do
      assert {:error, :not_found} = PaneStream.send_keys("nonexistent:0.0", "test")
    end
  end

  describe "output streaming" do
    test "receives output via PubSub", %{session: session} do
      target = "#{session}:0.0"

      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Send a command that produces output
      PaneStream.send_keys(target, "echo pane_stream_test_output\n")

      # Wait for output to arrive via PubSub
      assert_receive {:pane_output, ^target, _data}, 2000
    end
  end

  describe "grace period" do
    test "PaneStream terminates after grace period with no viewers", %{session: session} do
      target = "#{session}:0.0"

      # Grace period is 1s in test config
      {:ok, _history, pid} = PaneStream.subscribe(target)
      ref = Process.monitor(pid)

      PaneStream.unsubscribe(target)

      # Grace period is 100ms in test config
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end

    test "re-subscribe during grace period keeps PaneStream alive", %{session: session} do
      target = "#{session}:0.0"

      {:ok, _history, pid} = PaneStream.subscribe(target)
      PaneStream.unsubscribe(target)

      # Re-subscribe before grace period (100ms) expires
      Process.sleep(50)
      {:ok, _history, pid2} = PaneStream.subscribe(target)
      assert pid == pid2

      # Should still be alive after original grace period would have expired
      Process.sleep(200)
      assert Process.alive?(pid)
    end
  end

  describe "dimensions/1" do
    test "returns current pane dimensions from tmux", %{session: session} do
      target = "#{session}:0.0"

      {:ok, _history, _pid} = PaneStream.subscribe(target)

      assert {:ok, {cols, rows}} = PaneStream.dimensions(target)
      assert is_integer(cols) and cols > 0
      assert is_integer(rows) and rows > 0
    end

    test "returns same shape as resize before/after", %{session: session} do
      target = "#{session}:0.0"

      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Detached test sessions can't resize beyond their default window dims,
      # so we only verify the function reports plausible values, not the exact
      # ones we asked for.
      assert {:ok, {c1, r1}} = PaneStream.dimensions(target)
      assert :ok = PaneStream.resize(target, 60, 20)
      assert {:ok, {c2, r2}} = PaneStream.dimensions(target)

      assert is_integer(c1) and is_integer(r1)
      assert is_integer(c2) and is_integer(r2)
    end

    test "returns error for nonexistent pane" do
      assert {:error, _} = PaneStream.dimensions("nonexistent:0.0")
    end
  end

  describe "pane death detection" do
    test "broadcasts pane_dead when pane is killed", %{session: session} do
      target = "#{session}:0.0"

      {:ok, _history, pid} = PaneStream.subscribe(target)
      ref = Process.monitor(pid)

      # Kill the session (which kills all its panes)
      System.cmd("tmux", ["kill-session", "-t", session])

      # Should receive pane_dead and PaneStream should terminate
      assert_receive {:pane_dead, ^target}, 3000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end
  end
end
