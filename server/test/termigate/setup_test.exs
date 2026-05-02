defmodule Termigate.SetupTest do
  use ExUnit.Case, async: true

  alias Termigate.Setup

  describe "init/1 with explicit :token opt" do
    test "uses the provided token" do
      pid = start_supervised!({Setup, name: :setup_test_a, token: "abc123"})
      assert is_pid(pid)
      assert Setup.token(:setup_test_a) == "abc123"
      assert Setup.required?(:setup_test_a)
    end
  end

  describe "valid_token?/1" do
    setup do
      start_supervised!({Setup, name: :setup_test_b, token: "good-token"})
      :ok
    end

    test "returns true for matching token" do
      assert Setup.valid_token?("good-token", :setup_test_b)
    end

    test "returns false for wrong token" do
      refute Setup.valid_token?("bad-token", :setup_test_b)
    end

    test "returns false for nil" do
      refute Setup.valid_token?(nil, :setup_test_b)
    end

    test "returns false for non-binary" do
      refute Setup.valid_token?(12_345, :setup_test_b)
    end
  end

  describe "consume/0" do
    setup do
      start_supervised!({Setup, name: :setup_test_c, token: "burnable"})
      :ok
    end

    test "wipes the token; subsequent valid_token?/1 always returns false" do
      assert Setup.valid_token?("burnable", :setup_test_c)
      assert :ok = Setup.consume(:setup_test_c)
      refute Setup.valid_token?("burnable", :setup_test_c)
      assert Setup.token(:setup_test_c) == nil
      refute Setup.required?(:setup_test_c)
    end

    test "is idempotent" do
      assert :ok = Setup.consume(:setup_test_c)
      assert :ok = Setup.consume(:setup_test_c)
    end
  end

  describe "replace/1" do
    setup do
      start_supervised!({Setup, name: :setup_test_d, token: "initial"})
      :ok
    end

    test "swaps the token in place" do
      assert :ok = Setup.replace(:setup_test_d, "swapped")
      assert Setup.token(:setup_test_d) == "swapped"
      assert Setup.valid_token?("swapped", :setup_test_d)
      refute Setup.valid_token?("initial", :setup_test_d)
    end

    test "accepts nil to disable the gate" do
      assert :ok = Setup.replace(:setup_test_d, nil)
      refute Setup.required?(:setup_test_d)
    end
  end
end
