defmodule Termigate.LayoutPollerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Termigate.LayoutPoller

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Swap to MockCommandRunner for these tests
    original = Application.get_env(:termigate, :command_runner)
    Application.put_env(:termigate, :command_runner, Termigate.MockCommandRunner)

    # Stub all commands by default so background processes (SessionPoller, LayoutPoller)
    # don't crash with Mox.UnexpectedCallError when they poll
    Mox.stub_with(Termigate.MockCommandRunner, Termigate.StubCommandRunner)

    on_exit(fn -> Application.put_env(:termigate, :command_runner, original) end)

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

      Termigate.MockCommandRunner
      |> stub(:run, fn _ ->
        {:error, {"can't find window", 1}}
      end)

      {:ok, panes} = LayoutPoller.get(session, "0")
      assert panes == []
    end

    test "broadcasts empty layout only once while window stays missing", %{unique: n} do
      session = "lp_silence_#{n}"

      Termigate.MockCommandRunner
      |> stub(:run, fn
        ["list-panes", "-t", _, "-F", _] -> {:error, {"can't find window", 1}}
        args -> Termigate.StubCommandRunner.run(args)
      end)

      Phoenix.PubSub.subscribe(Termigate.PubSub, LayoutPoller.topic(session, "0"))

      {:ok, []} = LayoutPoller.get(session, "0")
      assert_receive {:layout_updated, []}, 500

      [{pid, _}] = Registry.lookup(Termigate.PaneRegistry, {:layout_poller, session, "0"})
      send(pid, :poll)
      send(pid, :poll)
      # Flush: a synchronous call after the sends ensures both :poll messages were processed
      _ = :sys.get_state(pid)

      refute_receive {:layout_updated, _}, 50
    end

    test "re-broadcasts layout when window comes back", %{unique: n} do
      session = "lp_recover_#{n}"
      pid_holder = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Termigate.MockCommandRunner
      |> stub(:run, fn
        ["list-panes", "-t", _, "-F", _] ->
          count = Agent.get_and_update(counter, &{&1, &1 + 1})

          if count == 0 do
            {:error, {"can't find window", 1}}
          else
            send(pid_holder, {:polled, count})
            {:ok, "%0\t0\t0\t80\t24\t0\tbash\n"}
          end

        args ->
          Termigate.StubCommandRunner.run(args)
      end)

      Phoenix.PubSub.subscribe(Termigate.PubSub, LayoutPoller.topic(session, "0"))

      {:ok, []} = LayoutPoller.get(session, "0")
      assert_receive {:layout_updated, []}, 500

      [{pid, _}] = Registry.lookup(Termigate.PaneRegistry, {:layout_poller, session, "0"})
      send(pid, :poll)

      assert_receive {:layout_updated, [%{pane_id: "%0"}]}, 500
    end

    test "parses tab-separated pane layout lines", %{unique: n} do
      session = "lp_parse_#{n}"

      Termigate.MockCommandRunner
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
