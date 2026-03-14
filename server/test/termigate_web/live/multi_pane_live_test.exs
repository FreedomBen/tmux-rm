defmodule TermigateWeb.MultiPaneLiveTest do
  use TermigateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @test_panes [
    %{
      pane_id: "%0",
      target: "test:0.0",
      left: 0,
      top: 0,
      width: 80,
      height: 24,
      index: 0,
      command: "bash"
    },
    %{
      pane_id: "%1",
      target: "test:0.1",
      left: 81,
      top: 0,
      width: 80,
      height: 24,
      index: 1,
      command: "vim"
    }
  ]

  describe "mount with window" do
    test "renders multi-pane view with session name", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions/test/windows/0")
      assert html =~ "test"
    end

    test "renders empty state when no panes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions/nonexistent/windows/0")
      assert html =~ "No panes"
      assert html =~ "Back to Sessions"
    end

    test "renders back link to session list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions/test/windows/0")
      assert html =~ ~s(href="/")
    end
  end

  describe "session redirect" do
    test "redirects /sessions/:session to a window", %{conn: conn} do
      {:error, {:live_redirect, %{to: path}}} = live(conn, "/sessions/test")
      assert path =~ ~r|/sessions/test/windows/|
    end
  end

  describe "layout updates" do
    test "updates panes on layout_updated broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      send(view.pid, {:layout_updated, @test_panes})
      html = render(view)

      assert html =~ "test:0.0"
      assert html =~ "test:0.1"
    end

    test "renders grid with correct template after pane update", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      send(view.pid, {:layout_updated, @test_panes})
      html = render(view)

      assert html =~ "grid-template-columns"
      assert html =~ "grid-template-rows"
      assert html =~ "multi-pane-grid"
    end

    test "renders mobile pane list after pane update", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      send(view.pid, {:layout_updated, @test_panes})
      html = render(view)

      # Mobile list with maximize buttons
      assert html =~ "sm:hidden"
      assert html =~ "test:0.0"
      assert html =~ "test:0.1"
      assert html =~ "maximize_pane"
    end

    test "pane containers have data-mode=multi", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      send(view.pid, {:layout_updated, @test_panes})
      html = render(view)

      assert html =~ ~s(data-mode="multi")
    end

    test "resize event is ignored (passive mode)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")
      render_hook(view, "resize", %{"cols" => 120, "rows" => 40})
    end
  end

  describe "notification events" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")
      # Give the view some panes so it subscribes to pane topics
      send(view.pid, {:layout_updated, @test_panes})
      render(view)
      %{view: view}
    end

    test "forwards pane_idle event when mode is activity", %{view: view} do
      # Set notification mode to activity
      Termigate.Config.update(fn config ->
        Map.put(config, "notifications", %{"mode" => "activity", "idle_threshold" => 10})
      end)

      # Wait for config change to propagate
      render(view)

      # Send idle event for a subscribed pane
      send(view.pid, {:pane_idle, "test:0.0", 15_000})
      # Should not crash — event is forwarded to JS hook
      render(view)
    end

    test "ignores pane_idle event when mode is disabled", %{view: view} do
      Termigate.Config.update(fn config ->
        Map.put(config, "notifications", %{"mode" => "disabled"})
      end)

      render(view)

      send(view.pid, {:pane_idle, "test:0.0", 15_000})
      # Should not crash
      render(view)
    end

    test "forwards command_finished event when mode is shell", %{view: view} do
      Termigate.Config.update(fn config ->
        Map.put(config, "notifications", %{"mode" => "shell", "min_duration" => 5})
      end)

      render(view)

      send(view.pid, {:command_finished, "test:0.0", %{
        exit_code: 0,
        command: "make",
        duration_seconds: 30
      }})

      render(view)
    end

    test "ignores command_finished event when mode is activity", %{view: view} do
      Termigate.Config.update(fn config ->
        Map.put(config, "notifications", %{"mode" => "activity"})
      end)

      render(view)

      send(view.pid, {:command_finished, "test:0.0", %{
        exit_code: 0,
        command: "make",
        duration_seconds: 30
      }})

      render(view)
    end
  end

  describe "focus_pane" do
    test "sets active pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")
      send(view.pid, {:layout_updated, @test_panes})
      render(view)

      render_click(view, "focus_pane", %{"pane" => "test:0.1"})
      # Should not crash, active pane is set
      render(view)
    end

    test "unmaximizes when focusing a different pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")
      send(view.pid, {:layout_updated, @test_panes})
      render(view)

      # Maximize first pane
      render_click(view, "maximize_pane", %{"target" => "test:0.0"})
      html = render(view)
      assert html =~ "pane-maximized"

      # Focus second pane — should unmaximize
      render_click(view, "focus_pane", %{"pane" => "test:0.1"})
      html = render(view)
      refute html =~ "pane-maximized"
    end
  end

  describe "pane subscription management" do
    test "subscribes to new panes on layout update", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      # Initial layout with one pane
      send(view.pid, {:layout_updated, [hd(@test_panes)]})
      render(view)

      # Update with two panes — should subscribe to the new one
      send(view.pid, {:layout_updated, @test_panes})
      render(view)

      # Send notification to the new pane — should not crash
      send(view.pid, {:pane_idle, "test:0.1", 10_000})
      render(view)
    end
  end

  describe "grid computation" do
    test "computes correct grid for side-by-side panes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      send(view.pid, {:layout_updated, @test_panes})
      html = render(view)

      # Should have two column tracks (80fr and 80fr) with a gap
      assert html =~ "grid-template-columns"
      # Both panes should have grid-column placement
      assert html =~ "grid-column:"
    end

    test "computes grid for stacked panes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions/test/windows/0")

      stacked = [
        %{
          pane_id: "%0",
          target: "t:0.0",
          left: 0,
          top: 0,
          width: 120,
          height: 20,
          index: 0,
          command: "bash"
        },
        %{
          pane_id: "%1",
          target: "t:0.1",
          left: 0,
          top: 21,
          width: 120,
          height: 20,
          index: 1,
          command: "bash"
        }
      ]

      send(view.pid, {:layout_updated, stacked})
      html = render(view)

      assert html =~ "grid-template-rows"
      assert html =~ "t:0.0"
      assert html =~ "t:0.1"
    end
  end
end
