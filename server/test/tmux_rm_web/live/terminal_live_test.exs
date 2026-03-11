defmodule TmuxRmWeb.TerminalLiveTest do
  use TmuxRmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders terminal view with target", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/terminal/test:0.0")
      assert html =~ "terminal"
      assert html =~ "test:0.0"
      assert html =~ "channel-token"
    end

    test "includes channel token meta tag", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/terminal/mysession:1.2")
      assert html =~ ~r/meta name="channel-token" content="[^"]+"/
    end

    test "shows back link to sessions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/terminal/test:0.0")
      assert html =~ "Sessions"
    end
  end

  describe "resize event" do
    test "accepts resize event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/terminal/test:0.0")

      # Should not crash — PaneStream may not exist but that's ok
      render_hook(view, "resize", %{"cols" => 120, "rows" => 40})
    end
  end

  describe "pane_dead" do
    test "shows overlay when pane dies", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/terminal/test:0.0")

      send(view.pid, {:pane_dead, "test:0.0"})
      html = render(view)

      assert html =~ "Session ended"
      assert html =~ "Back to Sessions"
    end
  end
end
