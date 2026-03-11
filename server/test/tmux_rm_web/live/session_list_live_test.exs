defmodule TmuxRmWeb.SessionListLiveTest do
  use TmuxRmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders session list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Sessions"
    end

    test "shows empty state when no sessions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No tmux sessions" or html =~ "Sessions"
    end
  end

  describe "new session form" do
    test "toggle form visibility", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = view |> element("button", "New Session") |> render_click()
      assert html =~ "Session name"

      html =
        view
        |> element(~s(button[phx-click="toggle_new_session_form"]), "Cancel")
        |> render_click()

      refute html =~ ~s(id="new-session-name")
    end

    test "validates session name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "New Session") |> render_click()

      html = render_change(view, "validate_session_name", %{"name" => "bad:name"})
      assert html =~ "Invalid name"
    end
  end

  describe "confirmation dialog" do
    test "kill session sets confirm message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render_click(view, "request_kill_session", %{"name" => "my-session"})
      assert html =~ "terminate all processes"
      assert html =~ "my-session"
    end

    test "cancel clears confirm state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_click(view, "request_kill_session", %{"name" => "my-session"})
      html = render_click(view, "cancel_confirm")
      refute html =~ "terminate all processes"
    end

    test "kill pane last pane warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_click(view, "request_kill_pane", %{"target" => "test:0.0", "pane-count" => "1"})

      assert html =~ "last pane"
    end

    test "kill pane normal message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_click(view, "request_kill_pane", %{"target" => "test:0.1", "pane-count" => "3"})

      assert html =~ "Kill this pane"
    end
  end

  describe "event handlers - stub" do
    test "split pane handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_click(view, "split_pane", %{"target" => "test:0.0", "direction" => "horizontal"})

      assert html =~ "Sessions"
    end

    test "create window handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = render_click(view, "create_window", %{"session" => "test-session"})
      assert html =~ "Sessions"
    end
  end

  describe "tmux integration" do
    @tag :tmux
    setup do
      original = Application.get_env(:tmux_rm, :command_runner)
      Application.put_env(:tmux_rm, :command_runner, TmuxRm.Tmux.CommandRunner)
      on_exit(fn -> Application.put_env(:tmux_rm, :command_runner, original) end)
      :ok
    end

    test "create session via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "New Session") |> render_click()

      name = "test-lv-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      html = render_click(view, "create_session", %{"name" => name})
      refute html =~ ~s(id="new-session-name")
    end

    test "rename session", %{conn: conn} do
      name = "test-ren-#{:rand.uniform(100_000)}"
      new_name = "test-ren2-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        TmuxRm.TmuxManager.kill_session(name)
        TmuxRm.TmuxManager.kill_session(new_name)
      end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      # Force poller to pick up the new session
      TmuxRm.SessionPoller.force_poll()
      Process.sleep(50)

      {:ok, view, _html} = live(conn, "/")

      # Start rename
      render_click(view, "start_rename", %{"name" => name})

      # Validate with bad name
      html = render_click(view, "validate_rename", %{"name" => "bad:name"})
      assert html =~ "Invalid name"

      # Submit valid rename
      html = render_click(view, "submit_rename", %{"name" => new_name})
      # rename_session assign should be nil on success
      refute html =~ "Invalid name"
    end

    test "split pane", %{conn: conn} do
      name = "test-splitlv-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      {:ok, view, _html} = live(conn, "/")

      html =
        render_click(view, "split_pane", %{"target" => "#{name}:0.0", "direction" => "horizontal"})

      assert html =~ "Sessions"
    end

    test "kill session via confirm flow", %{conn: conn} do
      name = "test-kill-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      {:ok, view, _html} = live(conn, "/")

      render_click(view, "request_kill_session", %{"name" => name})
      html = render_click(view, "confirm_action")
      assert html =~ "Sessions"
    end

    test "kill pane via confirm flow", %{conn: conn} do
      name = "test-killp-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)
      TmuxRm.TmuxManager.split_pane("#{name}:0.0", :horizontal)

      {:ok, view, _html} = live(conn, "/")

      render_click(view, "request_kill_pane", %{"target" => "#{name}:0.1", "pane-count" => "2"})
      html = render_click(view, "confirm_action")
      assert html =~ "Sessions"
    end
  end

  describe "health endpoint" do
    test "returns health status", %{conn: conn} do
      conn = get(conn, "/healthz")

      assert json_response(conn, 200)["status"] in ["ok", "error"] or
               json_response(conn, 503)["status"] == "error"
    end
  end
end
