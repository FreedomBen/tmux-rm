defmodule Termigate.Auth do
  @moduledoc """
  Single-user authentication module.

  Credentials are stored in the `auth` section of config.yaml. Passwords are
  hashed with `pbkdf2_elixir` (PBKDF2-HMAC-SHA512) and stored in the
  self-identifying string format `$pbkdf2-sha512$<iters>$<salt>$<hash>` so
  that the algorithm and work factor can be migrated in the future without
  ambiguity.

  Hashes produced by older versions of termigate (the legacy
  `<base64salt>$<base64hash>` PBKDF2-HMAC-SHA256 / 100k-iteration format)
  are still verified, and are upgraded to the new format on the first
  successful login.

  Supports `TERMIGATE_AUTH_TOKEN` env var as a fallback authenticator.
  """

  require Logger

  @legacy_iterations 100_000
  @legacy_key_length 32
  @default_session_ttl_hours 168

  @doc "Verify credentials. Returns :ok or :error."
  @spec verify_credentials(String.t(), String.t()) :: :ok | :error
  def verify_credentials(username, password) do
    # Check static token first
    case Application.get_env(:termigate, :auth_token) do
      token when is_binary(token) and token != "" ->
        if Plug.Crypto.secure_compare(password, token),
          do: :ok,
          else: check_file(username, password)

      _ ->
        check_file(username, password)
    end
  end

  @doc """
  True if the static auth token is configured and matches the given password.
  Used by callers that need to distinguish a token-based login from a
  credentialed one (e.g. to log a `<token>` sentinel instead of the
  caller-supplied username).
  """
  @spec token_login?(String.t()) :: boolean()
  def token_login?(password) when is_binary(password) do
    case Application.get_env(:termigate, :auth_token) do
      token when is_binary(token) and token != "" ->
        Plug.Crypto.secure_compare(password, token)

      _ ->
        false
    end
  end

  def token_login?(_), do: false

  @doc "Returns true if auth is configured (auth section in config or token set)."
  @spec auth_enabled?() :: boolean()
  def auth_enabled? do
    case Application.get_env(:termigate, :auth_token) do
      token when is_binary(token) and token != "" ->
        true

      _ ->
        case read_auth() do
          {:ok, %{"username" => u, "password_hash" => h}}
          when is_binary(u) and u != "" and is_binary(h) and h != "" ->
            true

          _ ->
            false
        end
    end
  end

  @doc "Read stored credentials. Returns {:ok, {username, hash}} or {:error, :not_found}."
  @spec read_credentials() :: {:ok, {String.t(), String.t()}} | {:error, :not_found}
  def read_credentials do
    case read_auth() do
      {:ok, %{"username" => username, "password_hash" => hash}}
      when is_binary(username) and username != "" and is_binary(hash) and hash != "" ->
        {:ok, {username, hash}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Write credentials to config.yaml auth section."
  @spec write_credentials(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def write_credentials(username, password, session_ttl_hours \\ @default_session_ttl_hours) do
    hash = hash_password(password)

    auth_data = %{
      "username" => username,
      "password_hash" => hash,
      "session_ttl_hours" => session_ttl_hours
    }

    write_auth_section(auth_data)
  end

  @doc "Returns session TTL in hours from config."
  def session_ttl_hours do
    case read_auth() do
      {:ok, %{"session_ttl_hours" => hours}} when is_number(hours) and hours > 0 ->
        hours

      _ ->
        @default_session_ttl_hours
    end
  end

  @doc "Returns session TTL in seconds."
  def session_ttl_seconds do
    trunc(session_ttl_hours() * 3600)
  end

  @doc """
  Returns a stable version string derived from the active credentials, or
  `nil` when auth is not configured.

  The string is recomputed on every call from the current `password_hash`
  and `TERMIGATE_AUTH_TOKEN` env var, so it changes whenever the operator
  rotates either credential. Embedded in issued bearer tokens and cookie
  sessions so that previously issued tokens become invalid the moment a
  rotation happens — without needing a server-side denylist.
  """
  @spec auth_version() :: binary() | nil
  def auth_version do
    token =
      case Application.get_env(:termigate, :auth_token) do
        t when is_binary(t) -> t
        _ -> ""
      end

    hash =
      case read_credentials() do
        {:ok, {_user, h}} -> h
        _ -> ""
      end

    if token == "" and hash == "" do
      nil
    else
      :crypto.hash(:sha256, [token, 0, hash])
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)
    end
  end

  @doc "Update just the session TTL (hours)."
  def update_session_ttl(hours) when is_number(hours) and hours > 0 do
    case read_auth() do
      {:ok, auth} ->
        write_auth_section(Map.put(auth, "session_ttl_hours", hours))

      {:error, _} ->
        {:error, :no_auth_configured}
    end
  end

  @doc "Change password. Verifies current password, then sets new one."
  @spec change_password(String.t(), String.t()) ::
          :ok | {:error, :invalid_current | :no_auth | term()}
  def change_password(current_password, new_password) do
    case read_credentials() do
      {:ok, {username, stored_hash}} ->
        if verify_password(current_password, stored_hash) do
          new_hash = hash_password(new_password)

          case read_auth() do
            {:ok, auth} ->
              write_auth_section(Map.put(auth, "password_hash", new_hash))

            _ ->
              auth = %{
                "username" => username,
                "password_hash" => new_hash,
                "session_ttl_hours" => @default_session_ttl_hours
              }

              write_auth_section(auth)
          end
        else
          {:error, :invalid_current}
        end

      {:error, :not_found} ->
        {:error, :no_auth}
    end
  end

  @doc "Returns the default session TTL in hours."
  def default_session_ttl_hours, do: @default_session_ttl_hours

  @doc "Returns the config file path."
  def config_path do
    Termigate.Config.config_path()
  end

  @doc """
  Hash a password using PBKDF2-HMAC-SHA512 with a random salt. The returned
  string is in the self-identifying format
  `$pbkdf2-sha512$<iters>$<salt>$<hash>` produced by `pbkdf2_elixir`.
  """
  def hash_password(password) do
    Pbkdf2.hash_pwd_salt(password)
  end

  @doc """
  Verify a password against a stored hash. Accepts both the current
  self-identifying `$pbkdf2-sha512$...` format and the legacy
  `<base64salt>$<base64hash>` PBKDF2-HMAC-SHA256/100k format produced by
  pre-migration releases.
  """
  def verify_password(password, "$pbkdf2-" <> _ = stored_hash) when is_binary(password) do
    Pbkdf2.verify_pass(password, stored_hash)
  end

  def verify_password(password, stored_hash)
      when is_binary(password) and is_binary(stored_hash) do
    legacy_verify_password(password, stored_hash)
  end

  def verify_password(_password, _stored_hash), do: false

  @doc """
  Returns true when `stored_hash` is in the legacy format and should be
  rehashed to the current format on the next successful login.
  """
  @spec needs_rehash?(String.t()) :: boolean()
  def needs_rehash?("$pbkdf2-" <> _), do: false
  def needs_rehash?(stored_hash) when is_binary(stored_hash), do: true
  def needs_rehash?(_), do: false

  # --- Private ---

  defp read_auth do
    path = config_path()

    result =
      with {:ok, content} <- File.read(path),
           {:ok, parsed} when is_map(parsed) <- YamlElixir.read_from_string(content) do
        case parsed["auth"] do
          auth when is_map(auth) and map_size(auth) > 0 ->
            {:ok, auth}

          _ ->
            {:error, :not_found}
        end
      else
        _ -> {:error, :not_found}
      end

    case result do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> check_legacy_credentials()
    end
  end

  defp check_legacy_credentials do
    path = legacy_credentials_file()

    case File.read(path) do
      {:ok, content} ->
        case String.split(String.trim(content), ":", parts: 2) do
          [username, hash] when hash != "" ->
            auth = %{
              "username" => username,
              "password_hash" => hash,
              "session_ttl_hours" => @default_session_ttl_hours
            }

            case write_auth_section(auth) do
              :ok ->
                File.rm(path)
                Logger.info("Migrated credentials from legacy file to config.yaml")

              _ ->
                :ok
            end

            {:ok, auth}

          _ ->
            {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp legacy_credentials_file do
    Path.expand("~/.config/termigate/credentials")
  end

  defp write_auth_section(auth_data) do
    if GenServer.whereis(Termigate.Config) do
      case Termigate.Config.update(fn config ->
             Map.put(config, "auth", auth_data)
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      write_auth_direct(auth_data)
    end
  end

  defp write_auth_direct(auth_data) do
    path = config_path()
    dir = Path.dirname(path)

    existing =
      case File.read(path) do
        {:ok, content} ->
          case YamlElixir.read_from_string(content) do
            {:ok, parsed} when is_map(parsed) -> parsed
            _ -> Termigate.Config.defaults()
          end

        _ ->
          Termigate.Config.defaults()
      end

    updated = Map.put(existing, "auth", auth_data)

    yaml =
      case Ymlr.document(updated) do
        {:ok, doc} -> doc
        doc when is_binary(doc) -> doc
      end

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, yaml),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp check_file(username, password) do
    case read_credentials() do
      {:ok, {stored_user, stored_hash}} ->
        if Plug.Crypto.secure_compare(username, stored_user) do
          if verify_password(password, stored_hash) do
            maybe_upgrade_hash(stored_hash, password)
            :ok
          else
            :error
          end
        else
          # Dummy verify to prevent timing attacks
          verify_password("dummy", stored_hash)
          :error
        end

      {:error, :not_found} ->
        :error
    end
  end

  defp maybe_upgrade_hash(stored_hash, password) do
    if needs_rehash?(stored_hash) do
      new_hash = hash_password(password)

      if GenServer.whereis(Termigate.Config) do
        Termigate.Config.update(fn config ->
          case config["auth"] do
            %{} = auth -> Map.put(config, "auth", Map.put(auth, "password_hash", new_hash))
            _ -> config
          end
        end)

        Logger.info("Upgraded password hash to pbkdf2-sha512 format on successful login")
      end
    end

    :ok
  end

  defp legacy_verify_password(password, stored_hash) do
    case String.split(stored_hash, "$", parts: 2) do
      [salt_b64, hash_b64] ->
        with {:ok, salt} <- Base.decode64(salt_b64),
             {:ok, expected} <- Base.decode64(hash_b64) do
          dk = legacy_pbkdf2(password, salt)
          Plug.Crypto.secure_compare(dk, expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp legacy_pbkdf2(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @legacy_iterations, @legacy_key_length)
  end
end
