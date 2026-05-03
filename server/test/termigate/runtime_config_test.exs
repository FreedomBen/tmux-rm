defmodule Termigate.RuntimeConfigTest do
  # async: false because the tests mutate process env vars to drive the
  # decisions made by config/runtime.exs.
  use ExUnit.Case, async: false

  @runtime_config_path Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    previous_secure_cookies = System.get_env("TERMIGATE_SECURE_COOKIES")

    on_exit(fn ->
      case previous_secure_cookies do
        nil -> System.delete_env("TERMIGATE_SECURE_COOKIES")
        val -> System.put_env("TERMIGATE_SECURE_COOKIES", val)
      end
    end)

    System.delete_env("TERMIGATE_SECURE_COOKIES")
    :ok
  end

  defp termigate_app_config(env) do
    @runtime_config_path
    |> Config.Reader.read!(env: env)
    |> get_in([:termigate])
    |> List.wrap()
  end

  describe "secure_cookies" do
    # Default off mirrors force_ssl's default: plain-HTTP loopback / LAN /
    # Android-emulator deployments must keep working without manual cookie
    # tweaks. Read in :dev and :test envs (Config.Reader for :prod would
    # trigger the SECRET_KEY_BASE branch and raise).
    test "is disabled by default" do
      for env <- [:dev, :test] do
        assert Keyword.get(termigate_app_config(env), :secure_cookies) == false,
               "expected secure_cookies to default to false in #{env}"
      end
    end

    test "is disabled when TERMIGATE_SECURE_COOKIES is explicitly false" do
      System.put_env("TERMIGATE_SECURE_COOKIES", "false")
      assert Keyword.get(termigate_app_config(:test), :secure_cookies) == false
    end

    # Only the exact string "true" enables it. Anything else (yes, on, 1, …)
    # stays off so a typo never silently locks loopback users out of their
    # session cookie.
    test "is disabled when TERMIGATE_SECURE_COOKIES holds an unrecognized value" do
      for junk <- ["yes", "on", "1", "TRUE", "True", "enable", ""] do
        System.put_env("TERMIGATE_SECURE_COOKIES", junk)

        assert Keyword.get(termigate_app_config(:test), :secure_cookies) == false,
               "expected secure_cookies to be disabled for TERMIGATE_SECURE_COOKIES=#{inspect(junk)}"
      end
    end

    test "opt-in via TERMIGATE_SECURE_COOKIES=true enables the secure flag" do
      System.put_env("TERMIGATE_SECURE_COOKIES", "true")
      assert Keyword.get(termigate_app_config(:test), :secure_cookies) == true
    end

    # Regression: the previous implementation read TERMIGATE_SECURE_COOKIES at
    # *compile time* in prod.exs, which meant a release built with the env var
    # unset baked in `secure: false` and could not be flipped on without a
    # rebuild. The runtime path lifts that limitation.
    test "is read at config-load time, not at compile time" do
      # First load with the var unset — should be false.
      assert Keyword.get(termigate_app_config(:test), :secure_cookies) == false

      # Then flip the var and reload — should now be true *without* recompiling
      # anything between the two reads.
      System.put_env("TERMIGATE_SECURE_COOKIES", "true")
      assert Keyword.get(termigate_app_config(:test), :secure_cookies) == true
    end
  end
end
