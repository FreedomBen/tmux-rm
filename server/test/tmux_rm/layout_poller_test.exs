defmodule TmuxRm.LayoutPollerTest do
  use ExUnit.Case, async: false

  import Mox

  alias TmuxRm.LayoutPoller

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Swap to MockCommandRunner for these tests
    original = Application.get_env(:tmux_rm, :command_runner)
    Application.put_env(:tmux_rm, :command_runner, TmuxRm.MockCommandRunner)
    on_exit(fn -> Application.put_env(:tmux_rm, :command_runner, original) end)

    unique = :rand.uniform(1_000_000)
    %{unique: unique}
  end

  describe "topic" do
    test "topic format" do
      assert LayoutPoller.topic("mysession", "0") == "layout:mysession:0"
    end
  end

  describe "get/2" do
    test "returns empty list when window not found", %{unique: n} do
      session = "lp_empty_#{n}"

      TmuxRm.MockCommandRunner
      |> stub(:run, fn _ ->
        {:error, {"can't find window", 1}}
      end)

      {:ok, panes} = LayoutPoller.get(session, "0")
      assert panes == []
    end

    test "parses tab-separated pane layout lines", %{unique: n} do
      session = "lp_parse_#{n}"

      TmuxRm.MockCommandRunner
      |> stub(:run, fn
        ["list-panes", "-t", _target, "-F", _] ->
          {:ok, "%0\t0\t0\t80\t24\t0\tbash\n%1\t81\t0\t80\t24\t1\tvim\n"}

        _ ->
          {:error, {"not found", 1}}
      end)

      {:ok, panes} = LayoutPoller.get(session, "0")

      assert length(panes) == 2
      [p0, p1] = Enum.sort_by(panes, & &1.index)

      assert p0.pane_id == "%0"
      assert p0.left == 0
      assert p0.top == 0
      assert p0.width == 80
      assert p0.height == 24
      assert p0.target == "#{session}:0.0"
      assert p0.command == "bash"

      assert p1.pane_id == "%1"
      assert p1.left == 81
      assert p1.target == "#{session}:0.1"
      assert p1.command == "vim"
    end
  end
end
