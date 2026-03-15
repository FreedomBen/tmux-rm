defmodule Termigate.MCP.ToolsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  setup do
    original = Application.get_env(:termigate, :command_runner)
    Application.put_env(:termigate, :command_runner, Termigate.MockCommandRunner)
    Mox.stub_with(Termigate.MockCommandRunner, Termigate.StubCommandRunner)
    on_exit(fn -> Application.put_env(:termigate, :command_runner, original) end)
    :ok
  end

  setup :verify_on_exit!

  defp frame, do: Frame.new()

  defp extract_json({:reply, response, _frame}) do
    proto = Response.to_protocol(response)
    content = hd(proto["content"])
    Jason.decode!(content["text"])
  end

  defp extract_text({:reply, response, _frame}) do
    proto = Response.to_protocol(response)
    content = hd(proto["content"])
    content["text"]
  end

  defp is_error?({:reply, response, _frame}) do
    proto = Response.to_protocol(response)
    proto["isError"] == true
  end

  describe "ListSessions" do
    test "returns empty list when no sessions" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["list-sessions", "-F", _] ->
        {:error, {"no server running on /tmp/tmux-1000/default", 1}}
      end)

      result = Termigate.MCP.Tools.ListSessions.execute(%{}, frame())
      assert extract_json(result) == []
    end

    test "returns sessions list" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["list-sessions", "-F", _] ->
        {:ok, "dev\t3\t1700000000\t1\ntest\t1\t1700000100\t0"}
      end)

      result = Termigate.MCP.Tools.ListSessions.execute(%{}, frame())
      sessions = extract_json(result)
      assert length(sessions) == 2
      assert hd(sessions)["name"] == "dev"
      assert hd(sessions)["windows"] == 3
      assert hd(sessions)["attached"] == true
    end
  end

  describe "ListPanes" do
    test "returns panes grouped by window" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["list-panes", "-s", "-t", "dev", "-F", _] ->
        {:ok, "dev\t0\t0\t120\t40\tbash\t%0\ndev\t0\t1\t60\t40\tvim\t%1"}
      end)

      result = Termigate.MCP.Tools.ListPanes.execute(%{session: "dev"}, frame())
      data = extract_json(result)
      assert length(data) == 1
      window = hd(data)
      assert window["window"] == "0"
      assert length(window["panes"]) == 2
    end

    test "returns error for missing session" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["list-panes", "-s", "-t", "nope", "-F", _] ->
        {:error, {"can't find session nope", 1}}
      end)

      result = Termigate.MCP.Tools.ListPanes.execute(%{session: "nope"}, frame())
      assert is_error?(result)
    end
  end

  describe "CreateSession" do
    test "creates session successfully" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["new-session", "-d", "-s", "test", "-x", "120", "-y", "40"] ->
        {:ok, ""}
      end)

      result = Termigate.MCP.Tools.CreateSession.execute(%{name: "test"}, frame())
      data = extract_json(result)
      assert data["name"] == "test"
      assert data["target"] == "test:0.0"
    end

    test "creates session with custom dimensions" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["new-session", "-d", "-s", "test", "-x", "200", "-y", "50"] ->
        {:ok, ""}
      end)

      result =
        Termigate.MCP.Tools.CreateSession.execute(
          %{name: "test", cols: 200, rows: 50},
          frame()
        )

      data = extract_json(result)
      assert data["name"] == "test"
    end

    test "rejects invalid session name" do
      result = Termigate.MCP.Tools.CreateSession.execute(%{name: "bad name!"}, frame())
      assert is_error?(result)
      assert extract_text(result) =~ "Invalid session name"
    end
  end

  describe "KillSession" do
    test "kills session successfully" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["kill-session", "-t", "test"] -> {:ok, ""} end)

      result = Termigate.MCP.Tools.KillSession.execute(%{name: "test"}, frame())
      assert extract_text(result) =~ "killed"
    end
  end

  describe "KillPane" do
    test "kills pane successfully" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["kill-pane", "-t", "dev:0.1"] -> {:ok, ""} end)

      result = Termigate.MCP.Tools.KillPane.execute(%{target: "dev:0.1"}, frame())
      assert extract_text(result) =~ "killed"
    end
  end

  describe "ReadPane" do
    test "reads pane content with ANSI stripped" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "dev:0.0"] ->
        {:ok, "\e[32m$ hello\e[0m\n"}
      end)

      result = Termigate.MCP.Tools.ReadPane.execute(%{target: "dev:0.0"}, frame())
      data = extract_json(result)
      assert data["content"] == "$ hello\n"
    end

    test "reads pane content raw" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "dev:0.0"] ->
        {:ok, "\e[32m$ hello\e[0m\n"}
      end)

      result = Termigate.MCP.Tools.ReadPane.execute(%{target: "dev:0.0", raw: true}, frame())
      data = extract_json(result)
      assert data["content"] == "\e[32m$ hello\e[0m\n"
    end

    test "returns error for missing pane" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["capture-pane", "-p", "-t", "nope:0.0"] ->
        {:error, {"can't find pane", 1}}
      end)

      result = Termigate.MCP.Tools.ReadPane.execute(%{target: "nope:0.0"}, frame())
      assert is_error?(result)
    end
  end

  describe "ResizePane" do
    test "resizes with both dimensions" do
      Termigate.MockCommandRunner
      |> expect(:run, fn ["resize-pane", "-t", "dev:0.0", "-x", "200", "-y", "50"] ->
        {:ok, ""}
      end)

      result =
        Termigate.MCP.Tools.ResizePane.execute(
          %{target: "dev:0.0", cols: 200, rows: 50},
          frame()
        )

      data = extract_json(result)
      assert data["cols"] == 200
      assert data["rows"] == 50
    end

    test "errors when no dimensions given" do
      result = Termigate.MCP.Tools.ResizePane.execute(%{target: "dev:0.0"}, frame())
      assert is_error?(result)
    end
  end
end
