defmodule Termigate.MCP.TmuxManagerCaptureTest do
  use ExUnit.Case, async: false

  import Mox

  setup do
    original = Application.get_env(:termigate, :command_runner)
    Application.put_env(:termigate, :command_runner, Termigate.MockCommandRunner)
    Mox.stub_with(Termigate.MockCommandRunner, Termigate.StubCommandRunner)
    on_exit(fn -> Application.put_env(:termigate, :command_runner, original) end)
    :ok
  end

  setup :verify_on_exit!

  describe "capture_pane/2" do
    test "captures visible pane content" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "dev:0.0"] ->
        {:ok, "$ hello world\n"}
      end)

      assert {:ok, "$ hello world\n"} = Termigate.TmuxManager.capture_pane("dev:0.0")
    end

    test "captures with escape sequences" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "dev:0.0", "-e"] ->
        {:ok, "\e[32m$ hello\e[0m\n"}
      end)

      assert {:ok, "\e[32m$ hello\e[0m\n"} =
               Termigate.TmuxManager.capture_pane("dev:0.0", escape: true)
    end

    test "captures with scrollback lines" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "dev:0.0", "-S", "-500"] ->
        {:ok, "scrollback content\n"}
      end)

      assert {:ok, "scrollback content\n"} =
               Termigate.TmuxManager.capture_pane("dev:0.0", lines: 500)
    end

    test "returns pane_not_found for missing pane" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "nope:0.0"] ->
        {:error, {"can't find pane nope:0.0", 1}}
      end)

      assert {:error, :pane_not_found} = Termigate.TmuxManager.capture_pane("nope:0.0")
    end

    test "returns error string for other failures" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "x:0.0"] ->
        {:error, {"some other error", 1}}
      end)

      assert {:error, "some other error"} = Termigate.TmuxManager.capture_pane("x:0.0")
    end
  end
end
