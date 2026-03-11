defmodule TmuxRmWeb.SetupLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.Auth

  @impl true
  def mount(_params, _session, socket) do
    # If auth is already configured, redirect to login
    if Auth.auth_enabled?() do
      {:ok, push_navigate(socket, to: "/login")}
    else
      socket =
        socket
        |> assign(:username, "")
        |> assign(:password, "")
        |> assign(:password_confirm, "")
        |> assign(:session_ttl_hours, "168")
        |> assign(:error, nil)
        |> assign(:page_title, "Setup")

      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-[60vh]">
      <div class="card bg-base-200 shadow-lg w-full max-w-sm">
        <div class="card-body">
          <h2 class="card-title text-center mb-2">Welcome to tmux-rm</h2>
          <p class="text-sm text-base-content/60 text-center mb-4">
            Create an account to secure your terminal access.
          </p>

          <form phx-submit="setup" class="space-y-4">
            <div>
              <label class="label" for="username">Username</label>
              <input
                type="text"
                id="username"
                name="username"
                value={@username}
                class="input input-bordered w-full"
                autocomplete="username"
                autofocus
              />
            </div>
            <div>
              <label class="label" for="password">Password</label>
              <input
                type="password"
                id="password"
                name="password"
                class="input input-bordered w-full"
                autocomplete="new-password"
              />
            </div>
            <div>
              <label class="label" for="password_confirm">Confirm Password</label>
              <input
                type="password"
                id="password_confirm"
                name="password_confirm"
                class="input input-bordered w-full"
                autocomplete="new-password"
              />
            </div>
            <div>
              <label class="label" for="session_ttl_hours">Session Duration</label>
              <select
                id="session_ttl_hours"
                name="session_ttl_hours"
                class="select select-bordered w-full"
              >
                <option value="1">1 hour</option>
                <option value="8">8 hours</option>
                <option value="24">1 day</option>
                <option value="72">3 days</option>
                <option value="168" selected>1 week</option>
                <option value="720">30 days</option>
                <option value="8760">1 year</option>
              </select>
              <p class="text-xs text-base-content/60 mt-1">
                How long before you need to log in again.
              </p>
            </div>
            <p :if={@error} class="text-error text-sm">{@error}</p>
            <button type="submit" class="btn btn-primary w-full">Create Account</button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("setup", params, socket) do
    username = String.trim(params["username"] || "")
    password = params["password"] || ""
    password_confirm = params["password_confirm"] || ""

    cond do
      username == "" ->
        {:noreply, assign(socket, :error, "Username is required.")}

      String.length(username) < 2 ->
        {:noreply, assign(socket, :error, "Username must be at least 2 characters.")}

      String.length(password) < 8 ->
        {:noreply, assign(socket, :error, "Password must be at least 8 characters.")}

      password != password_confirm ->
        {:noreply, assign(socket, :error, "Passwords do not match.")}

      Auth.auth_enabled?() ->
        # Race condition: someone else set it up
        {:noreply, push_navigate(socket, to: "/login")}

      true ->
        session_ttl_hours = String.to_integer(params["session_ttl_hours"] || "168")

        case Auth.write_credentials(username, password, session_ttl_hours) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Account created. Please log in.")
             |> redirect(to: "/login")}

          {:error, reason} ->
            {:noreply, assign(socket, :error, "Failed to create account: #{inspect(reason)}")}
        end
    end
  end
end
