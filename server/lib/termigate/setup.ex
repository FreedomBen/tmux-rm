defmodule Termigate.Setup do
  @moduledoc """
  Owns the one-shot first-run setup token.

  Defends against the first-run admin takeover race where any caller that
  reaches the box between deploy and the operator's first `/setup` visit
  could pick the admin username and password.

  On boot:
    * If an admin already exists (`Termigate.Auth.auth_enabled?/0`), no token
      is loaded — the gate is irrelevant.
    * Otherwise the token is taken from the `TERMIGATE_SETUP_TOKEN` env var,
      or generated as 32 random bytes (URL-safe base64). The full setup URL
      is logged at warning level so operators see it via `podman logs` /
      `journalctl -u termigate`.

  Once `consume/0` is called (after a successful admin creation), the token
  is wiped from memory and `valid_token?/1` returns false for all inputs.
  """
  use GenServer

  require Logger

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Returns the current token, or nil if unset / consumed."
  @spec token() :: String.t() | nil
  def token(server \\ @name), do: GenServer.call(server, :token)

  @doc "Constant-time check that `candidate` matches the live token."
  @spec valid_token?(term()) :: boolean()
  def valid_token?(candidate, server \\ @name) do
    GenServer.call(server, {:valid_token?, candidate})
  end

  @doc """
  Burn the token after a successful admin creation. Idempotent.
  Subsequent `valid_token?/1` calls always return false.
  """
  @spec consume() :: :ok
  def consume(server \\ @name), do: GenServer.call(server, :consume)

  @doc "True if a token is currently active (gate is enforcing)."
  @spec required?() :: boolean()
  def required?(server \\ @name), do: GenServer.call(server, :required?)

  @doc false
  # Test-only: directly set the token (bypassing env/generated-on-init logic)
  # so plug and LiveView tests can drive the global instance into a known
  # state without restarting it.
  def replace(server \\ @name, token) when is_nil(token) or is_binary(token) do
    GenServer.call(server, {:replace, token})
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state =
      cond do
        token = Keyword.get(opts, :token) ->
          %{token: token, source: :test}

        Termigate.Auth.auth_enabled?() ->
          %{token: nil, source: :no_admin_needed}

        env_token = System.get_env("TERMIGATE_SETUP_TOKEN") ->
          state = %{token: env_token, source: :env}
          log_setup_url(state)
          state

        true ->
          state = %{token: generate_token(), source: :generated}
          log_setup_url(state)
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:token, _from, state), do: {:reply, state.token, state}

  def handle_call({:valid_token?, _candidate}, _from, %{token: nil} = state) do
    {:reply, false, state}
  end

  def handle_call({:valid_token?, candidate}, _from, %{token: token} = state)
      when is_binary(candidate) do
    {:reply, Plug.Crypto.secure_compare(candidate, token), state}
  end

  def handle_call({:valid_token?, _candidate}, _from, state), do: {:reply, false, state}

  def handle_call(:consume, _from, %{token: nil} = state), do: {:reply, :ok, state}

  def handle_call(:consume, _from, state) do
    Logger.info("Setup token consumed; /setup gate is now closed.")
    {:reply, :ok, %{state | token: nil}}
  end

  def handle_call(:required?, _from, state), do: {:reply, state.token != nil, state}

  def handle_call({:replace, token}, _from, state), do: {:reply, :ok, %{state | token: token}}

  # --- Private ---

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp log_setup_url(%{token: token, source: source}) do
    {host, port} = endpoint_url_components()
    url = "http://#{host}:#{port}/setup?token=#{token}"
    src_note = if source == :env, do: "TERMIGATE_SETUP_TOKEN env var", else: "auto-generated"

    Logger.warning("""

    =============================================================================
    First-run setup required — no admin account exists.

    Open this URL in your browser to create the admin account:

      #{url}

    The /setup endpoint is restricted to loopback (127.0.0.1) and requires the
    token above. If termigate is on a remote host, tunnel the port over SSH:

      ssh -L #{port}:127.0.0.1:#{port} user@host

    Then open the URL above in your local browser. The token (#{src_note}) is
    burned after the first successful admin creation.
    =============================================================================
    """)
  end

  defp endpoint_url_components do
    config = Application.get_env(:termigate, TermigateWeb.Endpoint, [])
    http = Keyword.get(config, :http, [])
    port = Keyword.get(http, :port, 8888)
    {"127.0.0.1", port}
  end
end
