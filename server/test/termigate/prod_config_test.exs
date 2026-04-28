defmodule Termigate.ProdConfigTest do
  # async: false because the tests mutate process env vars to drive the
  # compile-time-style decisions made by config/prod.exs.
  use ExUnit.Case, async: false

  @prod_config_path Path.expand("../../config/prod.exs", __DIR__)

  setup do
    previous = System.get_env("TERMIGATE_FORCE_SSL")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("TERMIGATE_FORCE_SSL")
        val -> System.put_env("TERMIGATE_FORCE_SSL", val)
      end
    end)

    System.delete_env("TERMIGATE_FORCE_SSL")
    :ok
  end

  defp endpoint_config do
    @prod_config_path
    |> Config.Reader.read!()
    |> get_in([:termigate, TermigateWeb.Endpoint])
    |> List.wrap()
  end

  describe "force_ssl" do
    # Regression: ANDROID_DRIVE_01.md Bug 1.
    # The previous prod.exs hardcoded
    #   force_ssl: [exclude: [hosts: ["localhost", "127.0.0.1"]]]
    # which 301-redirected the Android emulator (10.0.2.2) and any LAN
    # client to https://, breaking the prod container running plain HTTP.
    test "is disabled by default so Android emulator and LAN clients can connect over HTTP" do
      assert Keyword.get(endpoint_config(), :force_ssl) == false
    end

    test "is disabled when TERMIGATE_FORCE_SSL is explicitly false" do
      System.put_env("TERMIGATE_FORCE_SSL", "false")
      assert Keyword.get(endpoint_config(), :force_ssl) == false
    end

    test "opt-in via TERMIGATE_FORCE_SSL=true keeps Android emulator (10.0.2.2) excluded" do
      System.put_env("TERMIGATE_FORCE_SSL", "true")

      force_ssl = Keyword.get(endpoint_config(), :force_ssl)

      assert is_list(force_ssl), "expected a Plug.SSL options list, got: #{inspect(force_ssl)}"

      hosts = get_in(force_ssl, [:exclude, :hosts]) || []

      # Localhost addresses must remain excluded.
      assert "localhost" in hosts
      assert "127.0.0.1" in hosts

      # The Android emulator alias for the host machine must also be
      # excluded so `make android-install-debug` keeps working against
      # `http://10.0.2.2:<port>`.
      assert "10.0.2.2" in hosts
    end
  end
end
