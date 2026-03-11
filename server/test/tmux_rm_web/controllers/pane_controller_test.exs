defmodule TmuxRmWeb.PaneControllerTest do
  use TmuxRmWeb.ConnCase, async: false

  # tmux-tagged tests need real command runner
  setup context do
    if context[:tmux] do
      original = Application.get_env(:tmux_rm, :command_runner)
      Application.put_env(:tmux_rm, :command_runner, TmuxRm.Tmux.CommandRunner)
      on_exit(fn -> Application.put_env(:tmux_rm, :command_runner, original) end)
    end

    :ok
  end

  describe "POST /api/panes/:target/split" do
    @tag :tmux
    test "splits a pane horizontally", %{conn: conn} do
      name = "test-split-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      conn = post(conn, "/api/panes/#{name}:0.0/split", %{direction: "horizontal"})
      assert %{"status" => "created"} = json_response(conn, 201)
    end

    @tag :tmux
    test "splits a pane vertically", %{conn: conn} do
      name = "test-splitv-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      conn = post(conn, "/api/panes/#{name}:0.0/split", %{direction: "vertical"})
      assert %{"status" => "created"} = json_response(conn, 201)
    end

    test "returns error for non-existent pane", %{conn: conn} do
      conn = post(conn, "/api/panes/nonexistent:0.0/split", %{direction: "horizontal"})
      assert %{"error" => "split_failed"} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/panes/:target" do
    @tag :tmux
    test "kills a pane", %{conn: conn} do
      name = "test-killpane-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      # Split first so we have a pane to kill without ending the session
      TmuxRm.TmuxManager.split_pane("#{name}:0.0", :horizontal)

      conn = delete(conn, "/api/panes/#{name}:0.1")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
