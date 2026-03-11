defmodule TmuxRm.AuthTest do
  use ExUnit.Case, async: false

  alias TmuxRm.Auth

  @test_dir "/tmp/tmux-rm-test-auth"
  @test_creds_file Path.join(@test_dir, "credentials")

  setup do
    # Override credentials path for testing
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf(@test_dir) end)
    :ok
  end

  describe "hash_password/1 and verify_password/2" do
    test "round-trip works" do
      hash = Auth.hash_password("secret123")
      assert Auth.verify_password("secret123", hash)
      refute Auth.verify_password("wrong", hash)
    end

    test "different passwords produce different hashes" do
      h1 = Auth.hash_password("password1")
      h2 = Auth.hash_password("password2")
      refute h1 == h2
    end

    test "same password produces different hashes (random salt)" do
      h1 = Auth.hash_password("same")
      h2 = Auth.hash_password("same")
      refute h1 == h2
      # But both verify
      assert Auth.verify_password("same", h1)
      assert Auth.verify_password("same", h2)
    end
  end

  describe "verify_credentials/2 with auth_token" do
    setup do
      original = Application.get_env(:tmux_rm, :auth_token)
      Application.put_env(:tmux_rm, :auth_token, "test-token-123")

      on_exit(fn ->
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end)

      :ok
    end

    test "accepts matching token as password" do
      assert :ok = Auth.verify_credentials("anyuser", "test-token-123")
    end

    test "rejects wrong token" do
      assert :error = Auth.verify_credentials("anyuser", "wrong-token")
    end
  end

  describe "auth_enabled?/0" do
    test "returns false when no token and no credentials file" do
      original = Application.get_env(:tmux_rm, :auth_token)
      Application.delete_env(:tmux_rm, :auth_token)
      on_exit(fn -> if original, do: Application.put_env(:tmux_rm, :auth_token, original) end)

      refute Auth.auth_enabled?()
    end

    test "returns true when token is set" do
      original = Application.get_env(:tmux_rm, :auth_token)
      Application.put_env(:tmux_rm, :auth_token, "some-token")

      on_exit(fn ->
        if original,
          do: Application.put_env(:tmux_rm, :auth_token, original),
          else: Application.delete_env(:tmux_rm, :auth_token)
      end)

      assert Auth.auth_enabled?()
    end
  end

  describe "verify_password edge cases" do
    test "returns false for malformed hash" do
      refute Auth.verify_password("test", "not-a-valid-hash")
      refute Auth.verify_password("test", "")
      refute Auth.verify_password("test", "bad$base64!")
    end
  end
end
