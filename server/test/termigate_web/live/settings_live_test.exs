defmodule TermigateWeb.SettingsLiveTest do
  use TermigateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Clear quick actions for each test, preserving auth and other config
    Termigate.Config.update(fn config -> Map.put(config, "quick_actions", []) end)

    on_exit(fn ->
      Termigate.Config.update(fn config -> Map.put(config, "quick_actions", []) end)
    end)

    :ok
  end

  describe "mount" do
    test "renders settings page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "Settings"
      assert html =~ "Quick Actions"
    end
  end

  describe "config file section" do
    test "shows bare path when not in a container", %{conn: conn} do
      Application.put_env(:termigate, :in_container?, false)
      on_exit(fn -> Application.delete_env(:termigate, :in_container?) end)

      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "Stored at"
      refute html =~ "inside the container"
    end

    test "calls out the host mount when running in a container", %{conn: conn} do
      Application.put_env(:termigate, :in_container?, true)
      on_exit(fn -> Application.delete_env(:termigate, :in_container?) end)

      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "inside the container"
      assert html =~ "/var/lib/termigate"
      assert html =~ "~/.config/termigate"
    end
  end

  describe "notifications section" do
    test "renders notification mode selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "Notifications"
      assert html =~ "Detection Mode"
      assert html =~ "Disabled"
      assert html =~ "Activity-based"
      assert html =~ "Shell integration"
    end

    test "changing mode to activity shows idle threshold", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "activity"
      })

      # Config change propagates via PubSub — re-render to pick it up
      html = render(view)

      assert html =~ "Idle threshold"
      assert html =~ "Play sound"
      assert html =~ "Request permission"
    end

    test "changing mode to shell shows min duration and snippets", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "shell"
      })

      html = render(view)

      assert html =~ "Minimum command duration"
      assert html =~ "Shell setup instructions"
    end

    test "changing mode to disabled hides options", %{conn: conn} do
      # First enable activity mode
      Termigate.Config.update(fn config ->
        Map.put(config, "notifications", %{"mode" => "activity"})
      end)

      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "disabled"
      })

      html = render(view)

      refute html =~ "Idle threshold"
      refute html =~ "Request permission"
    end

    test "persists notification settings to config", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "activity"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["mode"] == "activity"
    end

    test "updates idle threshold", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "activity"
      })

      render_click(view, "update_notification_setting", %{
        "key" => "idle_threshold",
        "value" => "30"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["idle_threshold"] == 30
    end

    test "toggles sound setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "activity"
      })

      render_click(view, "update_notification_setting", %{
        "key" => "sound",
        "value" => "true"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["sound"] == true
    end

    test "test_notification event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "activity"
      })

      # Should not crash
      render_click(view, "test_notification")
    end

    test "invalid numeric idle_threshold defaults to 10", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "idle_threshold",
        "value" => "abc"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["idle_threshold"] == 10
    end

    test "out-of-range idle_threshold is clamped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      # Above max (120)
      render_click(view, "update_notification_setting", %{
        "key" => "idle_threshold",
        "value" => "999"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["idle_threshold"] == 120

      # Below min (3)
      render_click(view, "update_notification_setting", %{
        "key" => "idle_threshold",
        "value" => "1"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["idle_threshold"] == 3
    end

    test "out-of-range min_duration is clamped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "min_duration",
        "value" => "9999"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["min_duration"] == 600
    end

    test "invalid mode falls back to disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "update_notification_setting", %{
        "key" => "mode",
        "value" => "invalid_mode"
      })

      config = Termigate.Config.get()
      assert config["notifications"]["mode"] == "disabled"
    end
  end

  describe "quick action CRUD" do
    test "add new action form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html = render_click(view, "new_action")
      assert html =~ "New Quick Action"
      assert html =~ "Label"
      assert html =~ "Command"
    end

    test "cancel edit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "new_action")
      html = render_click(view, "cancel_edit")
      refute html =~ "New Quick Action"
    end

    test "validates required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "new_action")

      html = render_click(view, "save_action", %{"action" => %{"label" => "", "command" => ""}})
      assert html =~ "required"
    end

    test "saves a new action", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "new_action")

      html =
        render_click(view, "save_action", %{
          "action" => %{"label" => "Test Action", "command" => "echo test", "color" => "green"}
        })

      # After save, the form should be gone and action should appear in list
      refute html =~ "New Quick Action"

      # Verify action was actually saved
      config = Termigate.Config.get()
      assert Enum.any?(config["quick_actions"], &(&1["label"] == "Test Action"))
    end

    test "edit existing action", %{conn: conn} do
      {:ok, _} = Termigate.Config.upsert_action(%{"label" => "Edit Me", "command" => "old"})
      config = Termigate.Config.get()
      id = hd(config["quick_actions"])["id"]

      {:ok, view, _html} = live(conn, "/settings")

      html = render_click(view, "edit_action", %{"id" => id})
      assert html =~ "Edit Quick Action"
    end

    test "delete action", %{conn: conn} do
      {:ok, _} = Termigate.Config.upsert_action(%{"label" => "ToDelete", "command" => "rm"})
      config = Termigate.Config.get()
      id = hd(config["quick_actions"])["id"]

      {:ok, view, html} = live(conn, "/settings")
      assert html =~ "ToDelete"

      render_click(view, "delete_action", %{"id" => id})

      # Verify deleted
      config = Termigate.Config.get()
      refute Enum.any?(config["quick_actions"], &(&1["label"] == "ToDelete"))
    end

    test "move actions up and down", %{conn: conn} do
      {:ok, _} = Termigate.Config.upsert_action(%{"label" => "First", "command" => "1"})
      {:ok, _} = Termigate.Config.upsert_action(%{"label" => "Second", "command" => "2"})
      config = Termigate.Config.get()
      second_id = Enum.at(config["quick_actions"], 1)["id"]

      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "move_up", %{"id" => second_id})

      config = Termigate.Config.get()
      assert hd(config["quick_actions"])["label"] == "Second"
    end
  end
end
