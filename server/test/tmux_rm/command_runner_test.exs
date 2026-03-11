defmodule TmuxRm.Tmux.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias TmuxRm.Tmux.CommandRunner

  @moduletag :tmux

  describe "run/1" do
    test "returns {:ok, stdout} on success" do
      assert {:ok, output} = CommandRunner.run(["list-commands"])
      assert is_binary(output)
    end

    test "returns {:error, {stderr, code}} on failure" do
      assert {:error, {msg, code}} =
               CommandRunner.run([
                 "kill-session",
                 "-t",
                 "nonexistent_session_#{:rand.uniform(999_999)}"
               ])

      assert is_binary(msg)
      assert is_integer(code)
      assert code > 0
    end

    test "prepends socket args when configured" do
      original = Application.get_env(:tmux_rm, :tmux_socket)

      try do
        Application.put_env(:tmux_rm, :tmux_socket, "/tmp/test-tmux-sock")
        # This will fail because the socket doesn't exist, but it proves socket args are used
        assert {:error, {msg, _code}} = CommandRunner.run(["list-sessions"])
        assert is_binary(msg)
      after
        if original,
          do: Application.put_env(:tmux_rm, :tmux_socket, original),
          else: Application.delete_env(:tmux_rm, :tmux_socket)
      end
    end
  end

  describe "run!/1" do
    test "returns stdout on success" do
      output = CommandRunner.run!(["list-commands"])
      assert is_binary(output)
    end

    test "raises on failure" do
      assert_raise RuntimeError, ~r/tmux command failed/, fn ->
        CommandRunner.run!([
          "kill-session",
          "-t",
          "nonexistent_session_#{:rand.uniform(999_999)}"
        ])
      end
    end
  end
end
