defmodule TermigateWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: true

  alias TermigateWeb.RateLimitStore

  # The rate-limit store's ETS table is process-global and isn't wiped between
  # tests for these `:test_*` keys (ConnCase deliberately skips them; see the
  # comment there). Random suffixes from `:rand.uniform(255)` collide between
  # concurrent test runs and leave stale counts in the bucket, which made
  # "blocks requests over limit" intermittently fire on the first call instead
  # of the sixth. `:erlang.unique_integer/0` is monotonic and unique within
  # the VM, so each call gets its own bucket key with no collisions.
  defp unique_ip(prefix), do: "#{prefix}.#{:erlang.unique_integer([:positive])}"

  describe "RateLimitStore.check/3" do
    test "allows requests under limit" do
      ip = unique_ip("10.0.0")
      assert :ok = RateLimitStore.check(ip, :test_endpoint, {5, 60})
      assert :ok = RateLimitStore.check(ip, :test_endpoint, {5, 60})
    end

    test "blocks requests over limit" do
      ip = unique_ip("10.1.0")

      for _ <- 1..5 do
        assert :ok = RateLimitStore.check(ip, :test_limit, {5, 60})
      end

      assert {:error, :rate_limited, _retry} = RateLimitStore.check(ip, :test_limit, {5, 60})
    end

    test "different IPs have independent limits" do
      ip1 = unique_ip("10.2.0")
      ip2 = unique_ip("10.3.0")

      for _ <- 1..5 do
        RateLimitStore.check(ip1, :test_indep, {5, 60})
      end

      assert {:error, :rate_limited, _} = RateLimitStore.check(ip1, :test_indep, {5, 60})
      assert :ok = RateLimitStore.check(ip2, :test_indep, {5, 60})
    end

    test "different keys have independent limits" do
      ip = unique_ip("10.4.0")

      for _ <- 1..5 do
        RateLimitStore.check(ip, :key_a, {5, 60})
      end

      assert {:error, :rate_limited, _} = RateLimitStore.check(ip, :key_a, {5, 60})
      assert :ok = RateLimitStore.check(ip, :key_b, {5, 60})
    end
  end
end
