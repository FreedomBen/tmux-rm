defmodule Termigate.AuthTest do
  use ExUnit.Case, async: false

  alias Termigate.Auth

  setup do
    :ok
  end

  describe "hash_password/1 and verify_password/2" do
    test "round-trip works" do
      hash = Auth.hash_password("secret123")
      assert Auth.verify_password("secret123", hash)
      refute Auth.verify_password("wrong", hash)
    end

    test "produces a self-identifying pbkdf2-sha512 hash string" do
      assert "$pbkdf2-sha512$" <> _ = Auth.hash_password("secret123")
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

    test "verifies legacy pbkdf2-sha256 hashes produced by older releases" do
      # Reproduce the old format inline so the test does not depend on
      # private helpers: 100k iterations of HMAC-SHA256 with a 16-byte salt,
      # base64-encoded as `<salt>$<hash>`.
      salt = :crypto.strong_rand_bytes(16)
      dk = :crypto.pbkdf2_hmac(:sha256, "legacy-pw", salt, 100_000, 32)
      legacy_hash = Base.encode64(salt) <> "$" <> Base.encode64(dk)

      assert Auth.verify_password("legacy-pw", legacy_hash)
      refute Auth.verify_password("wrong-pw", legacy_hash)
    end

    test "needs_rehash?/1 is true for legacy hashes and false for new ones" do
      assert Auth.needs_rehash?("salt$hash")
      refute Auth.needs_rehash?(Auth.hash_password("anything"))
    end
  end

  describe "lazy hash migration on successful login" do
    setup do
      # check_file/2 routes through Termigate.Config when the GenServer is
      # alive, so make sure the application is started for these tests.
      Application.ensure_all_started(:termigate)

      original_token = Application.get_env(:termigate, :auth_token)
      Application.delete_env(:termigate, :auth_token)

      on_exit(fn ->
        if GenServer.whereis(Termigate.Config) do
          Termigate.Config.update(fn cfg -> Map.delete(cfg, "auth") end)
        end

        if original_token,
          do: Application.put_env(:termigate, :auth_token, original_token),
          else: Application.delete_env(:termigate, :auth_token)
      end)

      :ok
    end

    defp install_legacy_credentials(username, password) do
      salt = :crypto.strong_rand_bytes(16)
      dk = :crypto.pbkdf2_hmac(:sha256, password, salt, 100_000, 32)
      legacy_hash = Base.encode64(salt) <> "$" <> Base.encode64(dk)

      {:ok, _} =
        Termigate.Config.update(fn cfg ->
          Map.put(cfg, "auth", %{
            "username" => username,
            "password_hash" => legacy_hash,
            "session_ttl_hours" => 24
          })
        end)

      legacy_hash
    end

    test "successful login with a legacy hash rewrites it to the new format" do
      legacy_hash = install_legacy_credentials("admin", "p@ssw0rd")

      assert :ok = Auth.verify_credentials("admin", "p@ssw0rd")

      stored = Termigate.Config.get()["auth"]["password_hash"]
      assert "$pbkdf2-sha512$" <> _ = stored
      refute stored == legacy_hash
      # Old password still verifies against the rewritten hash.
      assert Auth.verify_password("p@ssw0rd", stored)
    end

    test "failed login with a legacy hash does NOT rewrite the stored hash" do
      legacy_hash = install_legacy_credentials("admin", "right-pw")

      assert :error = Auth.verify_credentials("admin", "wrong-pw")

      assert Termigate.Config.get()["auth"]["password_hash"] == legacy_hash
    end

    test "successful login with an already-modern hash does not churn the config" do
      modern_hash = Auth.hash_password("p@ssw0rd")

      {:ok, _} =
        Termigate.Config.update(fn cfg ->
          Map.put(cfg, "auth", %{
            "username" => "admin",
            "password_hash" => modern_hash,
            "session_ttl_hours" => 24
          })
        end)

      assert :ok = Auth.verify_credentials("admin", "p@ssw0rd")
      # Same hash string preserved — no rewrite happened.
      assert Termigate.Config.get()["auth"]["password_hash"] == modern_hash
    end
  end

  describe "verify_credentials/2 with auth_token" do
    setup do
      original = Application.get_env(:termigate, :auth_token)
      Application.put_env(:termigate, :auth_token, "test-token-123")

      on_exit(fn ->
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
      end)

      :ok
    end

    test "accepts matching token as password" do
      assert :ok = Auth.verify_credentials("anyuser", "test-token-123")
    end

    test "rejects wrong token" do
      assert :error = Auth.verify_credentials("anyuser", "wrong-token")
    end

    test "token_login?/1 reports whether the password matched the static token" do
      assert Auth.token_login?("test-token-123")
      refute Auth.token_login?("wrong-token")
      refute Auth.token_login?("")
      refute Auth.token_login?(nil)
    end
  end

  describe "token_login?/1 without configured token" do
    setup do
      original = Application.get_env(:termigate, :auth_token)
      Application.delete_env(:termigate, :auth_token)
      on_exit(fn -> if original, do: Application.put_env(:termigate, :auth_token, original) end)
      :ok
    end

    test "returns false for any input" do
      refute Auth.token_login?("anything")
      refute Auth.token_login?("")
    end
  end

  describe "auth_enabled?/0" do
    test "returns false when no token and no credentials file" do
      original = Application.get_env(:termigate, :auth_token)
      Application.delete_env(:termigate, :auth_token)
      on_exit(fn -> if original, do: Application.put_env(:termigate, :auth_token, original) end)

      refute Auth.auth_enabled?()
    end

    test "returns true when token is set" do
      original = Application.get_env(:termigate, :auth_token)
      Application.put_env(:termigate, :auth_token, "some-token")

      on_exit(fn ->
        if original,
          do: Application.put_env(:termigate, :auth_token, original),
          else: Application.delete_env(:termigate, :auth_token)
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
