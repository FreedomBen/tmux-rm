defmodule TmuxRmWeb.AuthLiveTest do
  use TmuxRmWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "login page" do
    test "renders login form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/login")
      assert html =~ "Log in to tmux-rm"
      assert html =~ "Username"
      assert html =~ "Password"
    end

    test "shows auth not configured message when auth disabled", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/login")
      # Auth is not enabled in test mode by default
      assert html =~ "Auth is not configured"
    end
  end
end
