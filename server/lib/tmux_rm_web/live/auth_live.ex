defmodule TmuxRmWeb.AuthLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.Auth

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
    <div class="flex items-center justify-center min-h-[60vh]">
      <div class="card bg-base-200 shadow-lg w-full max-w-sm">
        <div class="card-body">
          <h2 class="card-title text-center mb-4">Log in to tmux-rm</h2>

          <form action="/login" method="post" class="space-y-4">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
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
            <button type="submit" class="btn btn-primary w-full">Log in</button>
          </form>
        </div>
      </div>
    </div>
    """
  end

end
