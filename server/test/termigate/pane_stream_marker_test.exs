defmodule Termigate.PaneStreamMarkerTest do
  @moduledoc "Unit tests for OSC marker scanning and stripping in PaneStream."
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

    # Enable shell integration mode
    Config.update(fn config ->
      Map.put(config, "notifications", %{
        "mode" => "shell",
        "idle_threshold" => 10,
        "min_duration" => 0,
        "sound" => false
      })
    end)

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

  describe "OSC marker scanning" do
    test "detects and strips marker from output, broadcasts command_finished", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Send an OSC marker as if the shell hook emitted it
      # \033]termigate;cmd_done;0;ls;3\007
      marker = "\\033]termigate;cmd_done;0;ls;3\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      # Should receive command_finished event
      assert_receive {:command_finished, ^target, metadata}, 3000
      assert metadata.exit_code == 0
      assert metadata.command == "ls"
      assert metadata.duration_seconds == 3
    end

    test "strips marker from pane output so it doesn't render", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Send visible text followed by a marker
      marker = "\\033]termigate;cmd_done;1;make;10\\007"
      PaneStream.send_keys(target, "printf 'visible#{marker}after'\n")

      # Collect output
      output = collect_output(target, 3000)

      # The printf output line should contain "visibleafter" with the marker stripped.
      # (The command echo line from the shell will still contain the literal printf args,
      # so we check specifically for the output line where visible and after are adjacent.)
      assert String.contains?(output, "visibleafter")

      # And we should get the notification
      assert_receive {:command_finished, ^target, %{exit_code: 1, command: "make"}}, 100
    end

    test "handles non-zero exit codes", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      marker = "\\033]termigate;cmd_done;127;notfound;0\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      assert_receive {:command_finished, ^target, metadata}, 3000
      assert metadata.exit_code == 127
      assert metadata.command == "notfound"
      assert metadata.duration_seconds == 0
    end

    test "ignores malformed markers", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Marker with wrong field count
      bad_marker = "\\033]termigate;cmd_done;0\\007"
      PaneStream.send_keys(target, "printf '#{bad_marker}'\n")

      refute_receive {:command_finished, ^target, _}, 2000
    end

    test "handles multiple markers in one chunk", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      m1 = "\\033]termigate;cmd_done;0;first;1\\007"
      m2 = "\\033]termigate;cmd_done;0;second;2\\007"
      PaneStream.send_keys(target, "printf '#{m1}#{m2}'\n")

      assert_receive {:command_finished, ^target, %{command: "first"}}, 3000
      assert_receive {:command_finished, ^target, %{command: "second"}}, 1000
    end

    test "sanitizes command name (truncation and non-printable chars)", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Command name with a tab character (non-printable) — use octal \011 for tab
      marker = "\\033]termigate;cmd_done;0;cmd\\011name;5\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      assert_receive {:command_finished, ^target, metadata}, 3000
      # Tab should be stripped
      assert metadata.command == "cmdname"
    end

    test "truncates command name to 128 characters", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Build a 200-char command name
      long_name = String.duplicate("a", 200)
      marker = "\\033]termigate;cmd_done;0;#{long_name};5\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      assert_receive {:command_finished, ^target, metadata}, 3000
      assert String.length(metadata.command) == 128
      assert metadata.command == String.duplicate("a", 128)
    end

    test "handles extreme exit codes and durations", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Very large exit code and duration
      marker = "\\033]termigate;cmd_done;255;cmd;999999\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      assert_receive {:command_finished, ^target, metadata}, 3000
      assert metadata.exit_code == 255
      assert metadata.duration_seconds == 999_999
    end

    test "ignores marker with non-integer exit code", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      marker = "\\033]termigate;cmd_done;abc;cmd;5\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      refute_receive {:command_finished, ^target, _}, 2000
    end

    test "ignores marker with non-integer duration", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      marker = "\\033]termigate;cmd_done;0;cmd;xyz\\007"
      PaneStream.send_keys(target, "printf '#{marker}'\n")

      refute_receive {:command_finished, ^target, _}, 2000
    end

    test "discards stale marker partial over 256 bytes and recovers", %{session: session} do
      target = "#{session}:0.0"
      {:ok, _history, _pid} = PaneStream.subscribe(target)

      # Send a false partial: marker start followed by >256 bytes of junk (no BEL).
      # The junk uses printable chars to avoid shell interpretation issues.
      junk = String.duplicate("x", 300)
      PaneStream.send_keys(target, "printf '\\033]termigate;#{junk}'\n")

      # Wait for the coalesce flush to process and store the oversized partial
      Process.sleep(200)

      # Now send a real valid marker — staleness guard should have discarded
      # the oversized partial, so this marker should be detected
      real_marker = "\\033]termigate;cmd_done;0;recovered;1\\007"
      PaneStream.send_keys(target, "printf '#{real_marker}'\n")

      assert_receive {:command_finished, ^target, %{command: "recovered"}}, 3000
    end
  end

  defp collect_output(target, timeout) do
    collect_output_acc(target, timeout, [])
  end

  defp collect_output_acc(target, timeout, acc) do
    receive do
      {:pane_output, ^target, data} ->
        collect_output_acc(target, timeout, [data | acc])
    after
      timeout ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
