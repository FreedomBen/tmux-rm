defmodule TermigateWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TermigateWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint TermigateWeb.Endpoint

      use TermigateWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TermigateWeb.ConnCase
    end
  end

  setup tags do
    # Enable auth with a test token so RequireAuth doesn't redirect to /setup.
    # Tests that need to test auth behavior directly can use @tag :skip_auth.
    if tags[:skip_auth] do
      Application.delete_env(:termigate, :auth_token)
    else
      Application.put_env(:termigate, :auth_token, "test-token")
    end

    # Ensure the application is running (may have been restarted by supervisor)
    Application.ensure_all_started(:termigate)

    # Reset the rate-limit bucket so tests can hit rate-limited routes without
    # bleeding state between tests (or test runs within the same minute).
    if :ets.whereis(:rate_limit_store) != :undefined do
      :ets.delete_all_objects(:rate_limit_store)
    end

    session =
      if tags[:skip_auth],
        do: %{},
        else: %{"authenticated_at" => System.system_time(:second)}

    # Sign an API bearer token for controller/API tests
    api_token = Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(session)
      |> Plug.Conn.put_req_header("authorization", "Bearer #{api_token}")

    {:ok, conn: conn}
  end
end
