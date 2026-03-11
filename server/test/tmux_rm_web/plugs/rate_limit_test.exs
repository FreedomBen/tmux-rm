defmodule TmuxRmWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: true

  alias TmuxRmWeb.RateLimitStore

  describe "RateLimitStore.check/3" do
    test "allows requests under limit" do
      ip = "10.0.0.#{:rand.uniform(255)}"
      assert :ok = RateLimitStore.check(ip, :test_endpoint, {5, 60})
      assert :ok = RateLimitStore.check(ip, :test_endpoint, {5, 60})
    end

    test "blocks requests over limit" do
      ip = "10.1.0.#{:rand.uniform(255)}"

      for _ <- 1..5 do
        assert :ok = RateLimitStore.check(ip, :test_limit, {5, 60})
      end

      assert {:error, :rate_limited, _retry} = RateLimitStore.check(ip, :test_limit, {5, 60})
    end

    test "different IPs have independent limits" do
      ip1 = "10.2.0.#{:rand.uniform(255)}"
      ip2 = "10.3.0.#{:rand.uniform(255)}"

      for _ <- 1..5 do
        RateLimitStore.check(ip1, :test_indep, {5, 60})
      end

      assert {:error, :rate_limited, _} = RateLimitStore.check(ip1, :test_indep, {5, 60})
      assert :ok = RateLimitStore.check(ip2, :test_indep, {5, 60})
    end

    test "different keys have independent limits" do
      ip = "10.4.0.#{:rand.uniform(255)}"

      for _ <- 1..5 do
        RateLimitStore.check(ip, :key_a, {5, 60})
      end

      assert {:error, :rate_limited, _} = RateLimitStore.check(ip, :key_a, {5, 60})
      assert :ok = RateLimitStore.check(ip, :key_b, {5, 60})
    end
  end
end
