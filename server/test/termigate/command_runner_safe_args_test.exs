defmodule Termigate.Tmux.CommandRunnerSafeArgsTest do
  use ExUnit.Case, async: true

  alias Termigate.Tmux.CommandRunner

  describe "safe_args/1" do
    test "redacts send-keys payload, keeps flags and target visible" do
      assert ["send-keys", "-H", "-t", "%5", "<4 arg(s) redacted>"] =
               CommandRunner.safe_args(["send-keys", "-H", "-t", "%5", "61", "6c", "6c", "6f"])
    end

    test "redacts literal send-keys text" do
      assert ["send-keys", "-t", "%5", "-l", "<1 arg(s) redacted>"] =
               CommandRunner.safe_args(["send-keys", "-t", "%5", "-l", "secret password"])
    end

    test "leaves send-keys with no payload alone" do
      assert ["send-keys", "-t", "%5"] = CommandRunner.safe_args(["send-keys", "-t", "%5"])
    end

    test "leaves non send-keys argv unchanged" do
      assert ["list-sessions", "-F", "format-string"] =
               CommandRunner.safe_args(["list-sessions", "-F", "format-string"])
    end
  end
end
