defmodule TmuxRmWeb.SessionControllerTest do
  use TmuxRmWeb.ConnCase, async: false

  describe "GET /api/sessions" do
    test "returns session list", %{conn: conn} do
      conn = get(conn, "/api/sessions")
      assert %{"sessions" => sessions} = json_response(conn, 200)
      assert is_list(sessions)
    end
  end

  describe "POST /api/sessions" do
    test "rejects invalid session name", %{conn: conn} do
      conn = post(conn, "/api/sessions", %{name: "bad:name"})
      assert %{"error" => "invalid_name"} = json_response(conn, 400)
    end

    test "returns error when name is missing", %{conn: conn} do
      conn = post(conn, "/api/sessions", %{})
      assert %{"error" => "validation_failed"} = json_response(conn, 400)
    end

    @tag :tmux
    test "creates a session with valid name", %{conn: conn} do
      name = "test-api-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      conn = post(conn, "/api/sessions", %{name: name})
      resp = json_response(conn, 201)
      assert resp["name"] == name
      assert resp["status"] == "created"
    end
  end

  describe "DELETE /api/sessions/:name" do
    @tag :tmux
    test "kills an existing session", %{conn: conn} do
      name = "test-del-#{:rand.uniform(100_000)}"
      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      conn = delete(conn, "/api/sessions/#{name}")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    @tag :tmux
    test "returns error for non-existent session", %{conn: conn} do
      conn = delete(conn, "/api/sessions/nonexistent-session-xyz")
      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/sessions/:name" do
    @tag :tmux
    test "renames a session", %{conn: conn} do
      old_name = "test-rename-#{:rand.uniform(100_000)}"
      new_name = "test-renamed-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        TmuxRm.TmuxManager.kill_session(old_name)
        TmuxRm.TmuxManager.kill_session(new_name)
      end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(old_name)

      conn = put(conn, "/api/sessions/#{old_name}", %{new_name: new_name})
      assert %{"name" => ^new_name, "status" => "renamed"} = json_response(conn, 200)
    end

    @tag :tmux
    test "rejects invalid new name", %{conn: conn} do
      name = "test-rename2-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      conn = put(conn, "/api/sessions/#{name}", %{new_name: "bad:name"})
      assert %{"error" => "invalid_name"} = json_response(conn, 400)
    end
  end

  describe "POST /api/sessions/:name/windows" do
    @tag :tmux
    test "creates a window in existing session", %{conn: conn} do
      name = "test-win-#{:rand.uniform(100_000)}"
      on_exit(fn -> TmuxRm.TmuxManager.kill_session(name) end)

      {:ok, _} = TmuxRm.TmuxManager.create_session(name)

      conn = post(conn, "/api/sessions/#{name}/windows")
      assert %{"status" => "created"} = json_response(conn, 201)
    end
  end

  # tmux-tagged tests need real command runner
  setup context do
    if context[:tmux] do
      original = Application.get_env(:tmux_rm, :command_runner)
      Application.put_env(:tmux_rm, :command_runner, TmuxRm.Tmux.CommandRunner)
      on_exit(fn -> Application.put_env(:tmux_rm, :command_runner, original) end)
    end

    :ok
  end
end
