defmodule Termigate.PaneStreamIdleTest do
  @moduledoc "Unit tests for PaneStream idle tracking and notification config handling."
  use ExUnit.Case

  import Termigate.TmuxHelpers

  alias Termigate.{Config, PaneStream}

  @moduletag :tmux

  setup do
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

  describe "idle detection" do
    test "broadcasts pane_idle after threshold when activity mode enabled", %{session: session} do
      # Enable activity mode with a short threshold
      Config.update(fn config ->
        Map.put(config, "notifications", %{
          "mode" => "activity",
          "idle_threshold" => 3,
          "min_duration" => 5,
          "sound" => false
        })
      end)

      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Send a command to trigger output
      PaneStream.send_keys(target, "echo idle_test\n")

      # Wait for output to arrive
      assert_receive {:pane_output, ^target, _data}, 2000

      # Should receive idle notification after the 3s threshold
      assert_receive {:pane_idle, ^target, _elapsed_ms}, 5000
    end

    test "does not broadcast pane_idle when mode is disabled", %{session: session} do
      Config.update(fn config ->
        Map.put(config, "notifications", %{
          "mode" => "disabled",
          "idle_threshold" => 3,
          "min_duration" => 5,
          "sound" => false
        })
      end)

      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      PaneStream.send_keys(target, "echo idle_disabled_test\n")
      assert_receive {:pane_output, ^target, _data}, 2000

      # Should NOT receive idle notification
      refute_receive {:pane_idle, ^target, _}, 4000
    end

    test "resets idle timer on new output", %{session: session} do
      Config.update(fn config ->
        Map.put(config, "notifications", %{
          "mode" => "activity",
          "idle_threshold" => 4,
          "min_duration" => 5,
          "sound" => false
        })
      end)

      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # First command
      PaneStream.send_keys(target, "echo first\n")
      assert_receive {:pane_output, ^target, _data}, 2000

      # Wait 2s then send another command — should reset the 4s timer
      Process.sleep(2000)
      PaneStream.send_keys(target, "echo second\n")
      assert_receive {:pane_output, ^target, _data}, 2000

      # Should NOT get idle within 2s of second command (timer was reset)
      refute_receive {:pane_idle, ^target, _}, 2000

      # But should get it after the full threshold from the last output
      assert_receive {:pane_idle, ^target, _elapsed_ms}, 4000
    end

    test "mode transition from disabled to activity starts timer", %{session: session} do
      # Start with disabled
      Config.update(fn config ->
        Map.put(config, "notifications", %{
          "mode" => "disabled",
          "idle_threshold" => 3,
          "min_duration" => 5,
          "sound" => false
        })
      end)

      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Generate output while disabled
      PaneStream.send_keys(target, "echo transition_test\n")
      assert_receive {:pane_output, ^target, _data}, 2000

      # Now enable activity mode — should start timer since there was recent activity
      Config.update(fn config ->
        Map.put(config, "notifications", %{
          "mode" => "activity",
          "idle_threshold" => 3,
          "min_duration" => 5,
          "sound" => false
        })
      end)

      # Should receive idle notification
      assert_receive {:pane_idle, ^target, _elapsed_ms}, 5000
    end
  end
end
