defmodule TermigateWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import TermigateWeb.ChannelCase

      @endpoint TermigateWeb.Endpoint
    end
  end

  setup _tags do
    # Ensure auth is enabled for channel tests (ConnCase also sets this for LiveView tests)
    Application.put_env(:termigate, :auth_token, "test-token")

    api_token =
      Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{
        username: "test",
        auth_version: Termigate.Auth.auth_version()
      })

    cookie_session = %{
      "authenticated_at" => System.system_time(:second),
      "auth_version" => Termigate.Auth.auth_version()
    }

    {:ok, api_token: api_token, cookie_session: cookie_session}
  end

  @doc """
  Connect to UserSocket using the cookie session path. Mirrors how a logged-in
  browser reaches the socket — the Plug session carries auth, no URL token.
  """
  defmacro connect_user_socket(cookie_session) do
    quote do
      Phoenix.ChannelTest.connect(
        TermigateWeb.UserSocket,
        %{},
        connect_info: %{session: unquote(cookie_session)}
      )
    end
  end
end
