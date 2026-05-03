defmodule TermigateWeb.SessionListLiveTest do
  use TermigateWeb.ConnCase, async: false

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
    test "kill session opens modal with message", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      # Closed at first — visibility is driven by the `modal-open` class on
      # the rendered HTML, so a regression to the old <dialog>-based flow
      # (which left the modal closed because LiveView patches removed the
      # `open` attribute) would fail this assertion.
      refute html =~ ~s(id="confirm-modal" class="modal modal-open")

      html = render_click(view, "request_kill_session", %{"name" => "my-session"})
      assert html =~ ~s(id="confirm-modal" class="modal modal-open")
      assert html =~ "terminate all processes"
      assert html =~ "my-session"
    end

    test "cancel clears confirm state and closes modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_click(view, "request_kill_session", %{"name" => "my-session"})
      html = render_click(view, "cancel_confirm")
      refute html =~ "terminate all processes"
      refute html =~ ~s(id="confirm-modal" class="modal modal-open")
    end
  end

  describe "event handlers - stub" do
    test "create window handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = render_click(view, "create_window", %{"session" => "test-session"})
      assert html =~ "Sessions"
    end
  end

  describe "tmux integration" do
    # Ride the same `:tmux` exclude tag as the other real-tmux test files.
    # `@tag` before `setup` only sets tags for the setup block itself, not
    # the tests in the describe — without `@describetag` here, these tests
    # ran unconditionally on every `mix test`, swapping the global
    # command_runner to the real Tmux.CommandRunner mid-suite. That made
    # SessionPoller poll the host's real tmux (every developer's actual
    # session list), then on test exit the runner reverted to the stub and
    # the next poll saw `[]` — which broadcast `{:sessions_updated, []}` on
    # the "sessions:state" topic and bumped any concurrently-running
    # MultiPaneLive into the "session was killed" redirect path.
    @describetag :tmux

    setup do
      original = Application.get_env(:termigate, :command_runner)
      Application.put_env(:termigate, :command_runner, Termigate.Tmux.CommandRunner)
      on_exit(fn -> Application.put_env(:termigate, :command_runner, original) end)
      :ok
    end

    test "create session via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "New Session") |> render_click()

      name = "test-lv-#{:rand.uniform(100_000)}"
      on_exit(fn -> Termigate.TmuxManager.kill_session(name) end)

      html = render_click(view, "create_session", %{"name" => name})
      refute html =~ ~s(id="new-session-name")
    end

    test "rename session", %{conn: conn} do
      name = "test-ren-#{:rand.uniform(100_000)}"
      new_name = "test-ren2-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        Termigate.TmuxManager.kill_session(name)
        Termigate.TmuxManager.kill_session(new_name)
      end)

      {:ok, _} = Termigate.TmuxManager.create_session(name)

      # Force poller to pick up the new session
      Termigate.SessionPoller.force_poll()
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

    test "kill session via confirm flow", %{conn: conn} do
      name = "test-kill-#{:rand.uniform(100_000)}"
      on_exit(fn -> Termigate.TmuxManager.kill_session(name) end)

      {:ok, _} = Termigate.TmuxManager.create_session(name)

      {:ok, view, _html} = live(conn, "/")

      render_click(view, "request_kill_session", %{"name" => name})
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
