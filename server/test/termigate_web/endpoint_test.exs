defmodule TermigateWeb.EndpointTest do
  # async: false because the tests mutate the :secure_cookies application
  # env, which is process-global.
  use ExUnit.Case, async: false

  alias TermigateWeb.Endpoint

  setup do
    previous = Application.fetch_env(:termigate, :secure_cookies)

    on_exit(fn ->
      case previous do
        :error -> Application.delete_env(:termigate, :secure_cookies)
        {:ok, val} -> Application.put_env(:termigate, :secure_cookies, val)
      end
    end)

    :ok
  end

  describe "runtime_session_options/0" do
    # When :secure_cookies is unset (or false), the cookie must be emitted
    # without Secure so plain-HTTP loopback / LAN / 10.0.2.2 emulator
    # workflows keep working. SameSite stays at "Lax" — Strict would break
    # cross-site GET-style navigations onto the app.
    test "returns secure: false and same_site: Lax when :secure_cookies is unset" do
      Application.delete_env(:termigate, :secure_cookies)

      opts = Endpoint.runtime_session_options()

      assert Keyword.fetch!(opts, :secure) == false
      assert Keyword.fetch!(opts, :same_site) == "Lax"
    end

    test "returns secure: false and same_site: Lax when :secure_cookies is false" do
      Application.put_env(:termigate, :secure_cookies, false)

      opts = Endpoint.runtime_session_options()

      assert Keyword.fetch!(opts, :secure) == false
      assert Keyword.fetch!(opts, :same_site) == "Lax"
    end

    # Once Secure is on, the deployment is committed to HTTPS, so we tighten
    # SameSite to Strict per the security review's recommendation. Pairs
    # with the High-fix auth-version revocation: a stolen cookie is harder
    # to replay across origins.
    test "returns secure: true and same_site: Strict when :secure_cookies is true" do
      Application.put_env(:termigate, :secure_cookies, true)

      opts = Endpoint.runtime_session_options()

      assert Keyword.fetch!(opts, :secure) == true
      assert Keyword.fetch!(opts, :same_site) == "Strict"
    end

    # Regression for the Medium-severity finding in
    # archived-docs/16_CLAUDE_SECURITY_REVIEW.md: the previous implementation
    # snapshotted :secure_cookies at compile time via
    # Application.compile_env/3, so flipping the runtime env var did nothing
    # without a rebuild. Verify the flip is observed without recompiling.
    test "reflects :secure_cookies changes at call time, not compile time" do
      Application.put_env(:termigate, :secure_cookies, false)
      assert Keyword.fetch!(Endpoint.runtime_session_options(), :secure) == false

      Application.put_env(:termigate, :secure_cookies, true)
      assert Keyword.fetch!(Endpoint.runtime_session_options(), :secure) == true
    end

    # Sanity: the static base values the WebSocket connect_info also relies
    # on must come through unchanged.
    test "preserves the static base (store, key, signing_salt)" do
      opts = Endpoint.runtime_session_options()

      assert Keyword.fetch!(opts, :store) == :cookie
      assert Keyword.fetch!(opts, :key) == "_termigate_key"
      assert Keyword.fetch!(opts, :signing_salt) == "KIiTW2EZ"
    end
  end
end
