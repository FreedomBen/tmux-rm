defmodule TmuxRmWeb.AuthLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.Auth

  @impl true
  def mount(_params, session, socket) do
    # If already authenticated, redirect to home
    if session["authenticated_at"] && Auth.auth_enabled?() do
      {:ok, push_navigate(socket, to: "/")}
    else
      socket =
        socket
        |> assign(:username, "")
        |> assign(:password, "")
        |> assign(:error, nil)
        |> assign(:auth_enabled, Auth.auth_enabled?())

      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-[60vh]">
      <div class="card bg-base-200 shadow-lg w-full max-w-sm">
        <div class="card-body">
          <h2 class="card-title text-center mb-4">Log in to tmux-rm</h2>

          <div :if={not @auth_enabled} role="alert" class="alert alert-info mb-4">
            <.icon name="hero-information-circle" class="size-5" />
            <span class="text-sm">Auth is not configured. Run <code>mix rca.setup</code> to enable.</span>
          </div>

          <form phx-submit="login" class="space-y-4">
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
                autocomplete="current-password"
              />
            </div>
            <p :if={@error} class="text-error text-sm">{@error}</p>
            <button type="submit" class="btn btn-primary w-full">Log in</button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("login", %{"username" => username, "password" => password}, socket) do
    case Auth.verify_credentials(username, password) do
      :ok ->
        {:noreply,
         socket
         |> push_event("set_session", %{authenticated_at: System.system_time(:second)})
         |> redirect(to: "/")}

      :error ->
        {:noreply, assign(socket, :error, "Invalid username or password.")}
    end
  end
end
