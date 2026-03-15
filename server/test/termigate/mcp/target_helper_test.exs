defmodule Termigate.MCP.TargetHelperTest do
  use ExUnit.Case, async: true

  alias Termigate.MCP.TargetHelper
  alias Termigate.Tmux.Pane

  describe "pane_target/1" do
    test "constructs target from pane struct" do
      pane = %Pane{session_name: "dev", window_index: 1, index: 2}
      assert TargetHelper.pane_target(pane) == "dev:1.2"
    end

    test "handles zero indices" do
      pane = %Pane{session_name: "main", window_index: 0, index: 0}
      assert TargetHelper.pane_target(pane) == "main:0.0"
    end
  end

  describe "session_from_target/1" do
    test "extracts session name" do
      assert TargetHelper.session_from_target("dev:0.0") == {:ok, "dev"}
    end

    test "handles session-only target" do
      assert TargetHelper.session_from_target("dev") == {:ok, "dev"}
    end

    test "handles session with window" do
      assert TargetHelper.session_from_target("dev:1") == {:ok, "dev"}
    end

    test "returns error for empty string" do
      assert TargetHelper.session_from_target("") == {:error, :invalid_target}
    end

    test "returns error for colon-only" do
      assert TargetHelper.session_from_target(":0.0") == {:error, :invalid_target}
    end
  end

  describe "valid_target?/1" do
    test "accepts session:window.pane format" do
      assert TargetHelper.valid_target?("dev:0.0")
    end

    test "accepts session:window format" do
      assert TargetHelper.valid_target?("dev:1")
    end

    test "accepts session-only format" do
      assert TargetHelper.valid_target?("dev")
    end

    test "accepts hyphens and underscores" do
      assert TargetHelper.valid_target?("my-session_1:0.0")
    end

    test "rejects empty string" do
      refute TargetHelper.valid_target?("")
    end

    test "rejects spaces" do
      refute TargetHelper.valid_target?("my session")
    end

    test "rejects non-string" do
      refute TargetHelper.valid_target?(123)
    end
  end
end
