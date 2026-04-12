defmodule TermigateWeb.AuthLive do
  use TermigateWeb, :live_view

  alias Termigate.Auth

  @impl true
  def mount(_params, session, socket) do
    # If already authenticated, redirect to home
    cond do
      not Auth.auth_enabled?() ->
        {:ok, push_navigate(socket, to: "/setup")}

      session["authenticated_at"] ->
        {:ok, push_navigate(socket, to: "/")}

      true ->
        socket =
          socket
          |> assign(:username, "")
          |> assign(:password, "")
          |> assign(:error, nil)

        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center min-h-screen px-4 py-8 gap-6 sm:gap-12">
      <img
        src={~p"/images/termigate-logo.png"}
        alt="termigate"
        class="w-48 h-auto"
      />
      <div class="card auth-card shadow-xl w-full max-w-sm rounded-2xl">
        <div class="card-body gap-6">
          <div class="text-center">
            <p class="text-xs text-base-content/40">Sign in to access your sessions</p>
          </div>

          <form action="/login" method="post" class="space-y-4">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <div>
              <label class="text-xs font-medium text-base-content/60 mb-1.5 block" for="username">
                Username
              </label>
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
              <label class="text-xs font-medium text-base-content/60 mb-1.5 block" for="password">
                Password
              </label>
              <input
                type="password"
                id="password"
                name="password"
                class="input input-bordered w-full"
                autocomplete="current-password"
              />
            </div>
            <button type="submit" class="btn btn-primary w-full">Sign in</button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
