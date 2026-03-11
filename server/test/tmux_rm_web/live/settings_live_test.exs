defmodule TmuxRmWeb.SettingsLiveTest do
  use TmuxRmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Reset config for each test
    TmuxRm.Config.update(fn _config -> %{"quick_actions" => []} end)

    on_exit(fn ->
      TmuxRm.Config.update(fn _config -> %{"quick_actions" => []} end)
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
      config = TmuxRm.Config.get()
      assert Enum.any?(config["quick_actions"], &(&1["label"] == "Test Action"))
    end

    test "edit existing action", %{conn: conn} do
      {:ok, _} = TmuxRm.Config.upsert_action(%{"label" => "Edit Me", "command" => "old"})
      config = TmuxRm.Config.get()
      id = hd(config["quick_actions"])["id"]

      {:ok, view, _html} = live(conn, "/settings")

      html = render_click(view, "edit_action", %{"id" => id})
      assert html =~ "Edit Quick Action"
    end

    test "delete action", %{conn: conn} do
      {:ok, _} = TmuxRm.Config.upsert_action(%{"label" => "ToDelete", "command" => "rm"})
      config = TmuxRm.Config.get()
      id = hd(config["quick_actions"])["id"]

      {:ok, view, html} = live(conn, "/settings")
      assert html =~ "ToDelete"

      render_click(view, "delete_action", %{"id" => id})

      # Verify deleted
      config = TmuxRm.Config.get()
      refute Enum.any?(config["quick_actions"], &(&1["label"] == "ToDelete"))
    end

    test "move actions up and down", %{conn: conn} do
      {:ok, _} = TmuxRm.Config.upsert_action(%{"label" => "First", "command" => "1"})
      {:ok, _} = TmuxRm.Config.upsert_action(%{"label" => "Second", "command" => "2"})
      config = TmuxRm.Config.get()
      second_id = Enum.at(config["quick_actions"], 1)["id"]

      {:ok, view, _html} = live(conn, "/settings")

      render_click(view, "move_up", %{"id" => second_id})

      config = TmuxRm.Config.get()
      assert hd(config["quick_actions"])["label"] == "Second"
    end
  end
end
