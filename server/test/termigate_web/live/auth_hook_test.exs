defmodule TermigateWeb.AuthHookTest do
  @moduledoc """
  Regression tests for the LiveView auth hook. The hook must read its TTL from
  `Termigate.Auth.session_ttl_seconds/0` (sourced from `auth.session_ttl_hours`
  in config.yaml) so it stays in sync with the HTTP `RequireAuth` plug.
  """
  use TermigateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Termigate.Config

  @moduletag :skip_auth

  setup do
    # Tests in this module manage auth_token / TTL directly; isolate them from
    # the global ConnCase setup that pre-populates a fresh authenticated session.
    Application.put_env(:termigate, :auth_token, "hook-test-token")
    set_session_ttl_hours(1)

    on_exit(fn ->
      if GenServer.whereis(Config) do
        Config.update(fn cfg -> Map.delete(cfg, "auth") end)
      end

      Application.put_env(:termigate, :auth_token, "test-token")
    end)

    :ok
  end

  defp set_session_ttl_hours(hours) do
    {:ok, _} =
      Config.update(fn cfg ->
        auth =
          (cfg["auth"] ||
             %{
               "username" => "admin",
               "password_hash" => Termigate.Auth.hash_password("placeholder")
             })
          |> Map.put("session_ttl_hours", hours)

        Map.put(cfg, "auth", auth)
      end)
  end

  defp build_conn_with(authenticated_at) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "authenticated_at" => authenticated_at,
      "auth_version" => Termigate.Auth.auth_version()
    })
  end

  describe "TTL at mount comes from auth.session_ttl_hours" do
    test "mount redirects to /login when session is older than configured TTL" do
      # 2 hours ago — past the 1-hour TTL set in setup.
      stale = System.system_time(:second) - 2 * 3600
      conn = build_conn_with(stale)

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")
    end

    test "mount succeeds when session is within configured TTL" do
      fresh = System.system_time(:second) - 60
      conn = build_conn_with(fresh)

      assert {:ok, _view, _html} = live(conn, "/")
    end

    test "default TTL applies when auth.session_ttl_hours is unset" do
      # Drop session_ttl_hours so the default (168h / 7d) is used.
      {:ok, _} =
        Config.update(fn cfg ->
          auth = Map.delete(cfg["auth"] || %{}, "session_ttl_hours")
          Map.put(cfg, "auth", auth)
        end)

      # 24 hours ago — well within the default 168h TTL.
      day_ago = System.system_time(:second) - 86_400
      conn = build_conn_with(day_ago)
      assert {:ok, _view, _html} = live(conn, "/")
    end
  end
end
