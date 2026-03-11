defmodule TmuxRm.Auth do
  @moduledoc """
  Single-user authentication module.

  Credentials are stored in ~/.config/tmux_rm/credentials as `username:salt$hash`.
  Uses PBKDF2-HMAC-SHA256 via Erlang :crypto. Supports RCA_AUTH_TOKEN env var as fallback.
  """

  require Logger

  @credentials_dir Path.expand("~/.config/tmux_rm")
  @credentials_file Path.join(@credentials_dir, "credentials")
  @iterations 100_000
  @key_length 32

  @doc "Verify credentials. Returns :ok or :error."
  @spec verify_credentials(String.t(), String.t()) :: :ok | :error
  def verify_credentials(username, password) do
    # Check static token first
    case Application.get_env(:tmux_rm, :auth_token) do
      token when is_binary(token) and token != "" ->
        if Plug.Crypto.secure_compare(password, token), do: :ok, else: check_file(username, password)

      _ ->
        check_file(username, password)
    end
  end

  @doc "Returns true if auth is configured (credentials file exists or token set)."
  @spec auth_enabled?() :: boolean()
  def auth_enabled? do
    case Application.get_env(:tmux_rm, :auth_token) do
      token when is_binary(token) and token != "" -> true
      _ -> File.exists?(@credentials_file)
    end
  end

  @doc "Read stored credentials."
  @spec read_credentials() :: {:ok, {String.t(), String.t()}} | {:error, :not_found}
  def read_credentials do
    case File.read(@credentials_file) do
      {:ok, content} ->
        case String.split(String.trim(content), ":", parts: 2) do
          [username, hash] when hash != "" -> {:ok, {username, hash}}
          _ -> {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Write credentials to file."
  @spec write_credentials(String.t(), String.t()) :: :ok | {:error, term()}
  def write_credentials(username, password) do
    hash = hash_password(password)

    with :ok <- File.mkdir_p(@credentials_dir),
         :ok <- File.chmod(@credentials_dir, 0o700),
         :ok <- File.write(@credentials_file, "#{username}:#{hash}"),
         :ok <- File.chmod(@credentials_file, 0o600) do
      :ok
    end
  end

  @doc "Returns the credentials directory path."
  def credentials_dir, do: @credentials_dir

  @doc "Returns the credentials file path."
  def credentials_file, do: @credentials_file

  @doc "Hash a password with a random salt using PBKDF2-HMAC-SHA256."
  def hash_password(password) do
    salt = :crypto.strong_rand_bytes(16)
    dk = pbkdf2(password, salt)
    Base.encode64(salt) <> "$" <> Base.encode64(dk)
  end

  @doc "Verify a password against a stored hash string."
  def verify_password(password, stored_hash) do
    case String.split(stored_hash, "$", parts: 2) do
      [salt_b64, hash_b64] ->
        with {:ok, salt} <- Base.decode64(salt_b64),
             {:ok, expected} <- Base.decode64(hash_b64) do
          dk = pbkdf2(password, salt)
          Plug.Crypto.secure_compare(dk, expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  # --- Private ---

  defp check_file(username, password) do
    case read_credentials() do
      {:ok, {stored_user, stored_hash}} ->
        if Plug.Crypto.secure_compare(username, stored_user) do
          if verify_password(password, stored_hash), do: :ok, else: :error
        else
          # Dummy verify to prevent timing attacks
          verify_password("dummy", stored_hash)
          :error
        end

      {:error, :not_found} ->
        :error
    end
  end

  defp pbkdf2(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, @key_length)
  end
end
