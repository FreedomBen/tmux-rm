defmodule TermigateWeb.SetupLiveTest do
  use TermigateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :skip_auth

  setup do
    Application.delete_env(:termigate, :auth_token)
    Termigate.Setup.replace("good-token")

    config_path = Application.get_env(:termigate, :config_path)
    File.rm(config_path)

    on_exit(fn ->
      Termigate.Setup.replace(nil)

      # The "creates admin" test writes credentials via
      # Termigate.Auth.write_credentials/3, which routes through the Config
      # GenServer and leaves the auth section in its in-memory state. If we
      # only File.rm/1 the disk file, the next test that calls Config.update
      # (quick actions, settings, multi-pane, etc.) will write the whole
      # cached state — auth section included — back to disk, leaving
      # auth_enabled?/0 returning true for the rest of the run. Clear the
      # in-memory auth before the rm so the GenServer holds a clean state.
      if GenServer.whereis(Termigate.Config) do
        Termigate.Config.update(fn config -> Map.delete(config, "auth") end)
      end

      File.rm(config_path)
      Application.put_env(:termigate, :auth_token, "test-token")
    end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  describe "mount" do
    test "renders setup form with valid token over loopback", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?token=good-token")
      assert html =~ "Username"
      assert html =~ "Confirm Password"
    end

    test "redirects to /login when token is missing", %{conn: conn} do
      # The plug 404s before LiveView mounts; assert that.
      conn = get(conn, "/setup")
      assert conn.status == 404
    end

    test "redirects to /login when token is wrong", %{conn: conn} do
      conn = get(conn, "/setup?token=wrong")
      assert conn.status == 404
    end

    test "redirects to /login when admin already configured", %{conn: conn} do
      Application.put_env(:termigate, :auth_token, "test-token")

      assert {:error, {:live_redirect, %{to: "/login"}}} =
               live(conn, "/setup?token=good-token")
    end
  end

  describe "form submission" do
    test "rejects when assigned token has been consumed mid-session", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?token=good-token")

      # Burn the token out from under the live session (e.g., another tab won
      # the race) — the next form submit must be rejected.
      Termigate.Setup.consume()

      assert {:error, {:live_redirect, %{to: "/login"}}} =
               view
               |> form("form", %{
                 "username" => "admin",
                 "password" => "password123",
                 "password_confirm" => "password123",
                 "session_ttl_hours" => "168"
               })
               |> render_submit()
    end

    test "creates admin and consumes token on success", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?token=good-token")

      # Submitting the form should create the admin, consume the token, and
      # redirect to /post-setup with a one-time login token.
      assert {:error, {:redirect, %{to: "/post-setup?token=" <> _}}} =
               view
               |> form("form", %{
                 "username" => "admin",
                 "password" => "password123",
                 "password_confirm" => "password123",
                 "session_ttl_hours" => "168"
               })
               |> render_submit()

      refute Termigate.Setup.required?()
      refute Termigate.Setup.valid_token?("good-token")
    end
  end
end
