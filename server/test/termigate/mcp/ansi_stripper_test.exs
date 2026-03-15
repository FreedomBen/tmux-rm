defmodule Termigate.MCP.AnsiStripperTest do
  use ExUnit.Case, async: true

  alias Termigate.MCP.AnsiStripper

  describe "strip/1" do
    test "strips CSI color sequences" do
      assert AnsiStripper.strip("\e[31mred text\e[0m") == "red text"
    end

    test "strips CSI sequences with multiple parameters" do
      assert AnsiStripper.strip("\e[1;32;40mbold green\e[0m") == "bold green"
    end

    test "strips cursor movement sequences" do
      assert AnsiStripper.strip("\e[2J\e[Hhello") == "hello"
    end

    test "strips OSC sequences" do
      assert AnsiStripper.strip("\e]0;window title\ahello") == "hello"
    end

    test "strips private mode sequences" do
      assert AnsiStripper.strip("\e[?25lhidden cursor\e[?25h") == "hidden cursor"
    end

    test "preserves plain text" do
      assert AnsiStripper.strip("hello world") == "hello world"
    end

    test "handles empty string" do
      assert AnsiStripper.strip("") == ""
    end

    test "handles string with only escapes" do
      assert AnsiStripper.strip("\e[31m\e[0m") == ""
    end

    test "preserves newlines and whitespace" do
      assert AnsiStripper.strip("line1\nline2\n") == "line1\nline2\n"
    end
  end
end
