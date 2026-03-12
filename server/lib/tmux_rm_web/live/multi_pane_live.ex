defmodule TmuxRmWeb.MultiPaneLive do
  @moduledoc """
  LiveView showing all panes in a tmux window in a CSS Grid layout.
  Mirrors tmux's split-pane layout with window tabs for navigation.
  Supports maximize/restore per pane.
  """
  use TmuxRmWeb, :live_view

  alias TmuxRm.{LayoutPoller, TmuxManager}

  require Logger

  @impl true
  def mount(%{"session" => session, "window" => window}, _session, socket) do
    window = to_string(window)

    if connected?(socket) do
      LayoutPoller.subscribe(session, window)
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:state")
    end

    # Fetch layout and window list
    layout =
      case LayoutPoller.get(session, window) do
        {:ok, panes} -> panes
        {:error, _} -> []
      end

    windows = fetch_windows(session)
    channel_token = Phoenix.Token.sign(socket, "channel", %{session: session})

    socket =
      socket
      |> assign(:session, session)
      |> assign(:window, window)
      |> assign(:panes, layout)
      |> assign(:grid, compute_grid(layout))
      |> assign(:windows, windows)
      |> assign(:maximized, nil)
      |> assign(:channel_token, channel_token)
      |> assign(:page_title, "#{session}:#{window}")

    {:ok, socket, layout: false}
  end

  def mount(%{"session" => session}, _session, socket) do
    # Redirect to active window
    active_window = get_active_window(session)

    {:ok,
     push_navigate(socket, to: "/sessions/#{session}/windows/#{active_window}", replace: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-dvh bg-black">
      <meta name="channel-token" content={@channel_token} />

      <%!-- Header bar --%>
      <div class="terminal-header-bar">
        <.link
          navigate={~p"/"}
          class="text-base-content/50 hover:text-base-content text-sm gap-1"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> <span class="hidden sm:inline">Sessions</span>
        </.link>
        <span class="text-base-content/70 text-sm font-mono tracking-tight">{@session}</span>
        <div class="w-10" />
      </div>

      <%!-- Window tabs --%>
      <div class="window-tabs">
        <div class="flex items-center gap-0.5 px-2 flex-1">
          <.link
            :for={win <- @windows}
            navigate={"/sessions/#{@session}/windows/#{win.index}"}
            class={[
              "window-tab",
              if(to_string(win.index) == @window,
                do: "window-tab-active",
                else: "window-tab-inactive"
              )
            ]}
          >
            Window {win.index}{if win.name, do: ": #{win.name}", else: ""}
          </.link>
        </div>
      </div>

      <%!-- Multi-pane grid (desktop/tablet) --%>
      <div
        :if={@panes != []}
        id="multi-pane-grid"
        class="flex-1 min-h-0 hidden sm:grid relative"
        style={"grid-template-columns: #{@grid.cols}; grid-template-rows: #{@grid.rows}; gap: 2px;"}
      >
        <%= for pane <- @panes do %>
          <div
            id={"pane-wrapper-#{pane.target}"}
            class={[
              "relative group min-h-0 overflow-hidden",
              if(@maximized == pane.target, do: "pane-maximized", else: "border border-base-content/5")
            ]}
            style={if @maximized == nil or @maximized == pane.target do
              if @maximized == pane.target do
                ""
              else
                "grid-column: #{pane_grid_col(pane, @grid)}; grid-row: #{pane_grid_row(pane, @grid)};"
              end
            else
              "display: none;"
            end}
          >
            <div
              id={"pane-#{pane.target}"}
              phx-hook="TerminalHook"
              phx-update="ignore"
              data-target={pane.target}
              data-mode="multi"
              class="w-full h-full"
            >
            </div>

            <%!-- Pane overlay controls --%>
            <div class="pane-overlay">
              <%= if @maximized == pane.target do %>
                <button
                  class="pane-overlay-btn"
                  phx-click="restore_pane"
                  title="Restore"
                >
                  <.icon name="hero-arrows-pointing-in-micro" class="size-4" />
                </button>
              <% else %>
                <button
                  class="pane-overlay-btn"
                  phx-click="maximize_pane"
                  phx-value-target={pane.target}
                  title="Maximize"
                >
                  <.icon name="hero-arrows-pointing-out-micro" class="size-4" />
                </button>
              <% end %>
              <.link
                navigate={"/terminal/#{pane.target}"}
                class="pane-overlay-btn"
                title="Open in full view"
              >
                <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
              </.link>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Mobile pane list — tappable cards navigate to terminal --%>
      <div :if={@panes != []} class="flex-1 overflow-y-auto sm:hidden p-3 space-y-2">
        <.link
          :for={pane <- @panes}
          navigate={"/terminal/#{pane.target}"}
          class="pane-row rounded-xl mobile-pane-card"
        >
          <.icon name="hero-command-line-micro" class="size-4 text-base-content/25 shrink-0" />
          <div class="flex-1 min-w-0">
            <div class="text-sm font-mono text-base-content/70">{pane.target}</div>
            <div class="text-xs text-base-content/40 mt-0.5">{pane.command} &middot; {pane.width}&times;{pane.height}</div>
          </div>
          <.icon name="hero-chevron-right-micro" class="size-4 text-base-content/20 shrink-0" />
        </.link>
      </div>

      <%!-- Empty state --%>
      <div :if={@panes == []} class="flex-1 flex items-center justify-center">
        <div class="empty-state">
          <.icon name="hero-rectangle-group" class="empty-state-icon" />
          <p class="text-lg font-semibold mb-2">No panes in this window</p>
          <.link navigate={~p"/"} class="btn btn-primary btn-sm">Back to Sessions</.link>
        </div>
      </div>
    </div>
    """
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info({:layout_updated, panes}, socket) do
    grid = compute_grid(panes)

    # If the maximized pane no longer exists, restore
    maximized =
      if socket.assigns.maximized &&
           not Enum.any?(panes, &(&1.target == socket.assigns.maximized)) do
        nil
      else
        socket.assigns.maximized
      end

    {:noreply, assign(socket, panes: panes, grid: grid, maximized: maximized)}
  end

  def handle_info({:sessions_updated, _sessions}, socket) do
    windows = fetch_windows(socket.assigns.session)
    {:noreply, assign(socket, :windows, windows)}
  end

  # Ignore pane output/control events — each TerminalHook handles its own via Channel
  def handle_info({:pane_output, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_dead, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_reconnected, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_resized, _, _}, socket), do: {:noreply, socket}
  def handle_info({:tmux_status_changed, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Event handlers ---

  @impl true
  def handle_event("maximize_pane", %{"target" => target}, socket) do
    {:noreply, assign(socket, :maximized, target)}
  end

  def handle_event("restore_pane", _params, socket) do
    {:noreply, assign(socket, :maximized, nil)}
  end

  def handle_event("resize", _params, socket) do
    # Multi-pane view is passive — ignore resize events
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:session] && socket.assigns[:window] do
      LayoutPoller.unsubscribe(socket.assigns.session, socket.assigns.window)
    end
  end

  # --- Grid computation ---

  defp compute_grid([]), do: %{cols: "1fr", rows: "1fr", col_bounds: [0], row_bounds: [0]}

  defp compute_grid(panes) do
    # Collect unique column and row boundaries
    col_bounds =
      panes
      |> Enum.flat_map(fn p -> [p.left, p.left + p.width] end)
      |> Enum.uniq()
      |> Enum.sort()

    row_bounds =
      panes
      |> Enum.flat_map(fn p -> [p.top, p.top + p.height] end)
      |> Enum.uniq()
      |> Enum.sort()

    # Compute track sizes as fr values
    col_tracks =
      col_bounds
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> "#{b - a}fr" end)
      |> Enum.join(" ")

    row_tracks =
      row_bounds
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> "#{b - a}fr" end)
      |> Enum.join(" ")

    %{
      cols: col_tracks || "1fr",
      rows: row_tracks || "1fr",
      col_bounds: col_bounds,
      row_bounds: row_bounds
    }
  end

  defp pane_grid_col(pane, grid) do
    start = Enum.find_index(grid.col_bounds, &(&1 == pane.left)) + 1
    finish = Enum.find_index(grid.col_bounds, &(&1 == pane.left + pane.width)) + 1
    "#{start} / #{finish}"
  end

  defp pane_grid_row(pane, grid) do
    start = Enum.find_index(grid.row_bounds, &(&1 == pane.top)) + 1
    finish = Enum.find_index(grid.row_bounds, &(&1 == pane.top + pane.height)) + 1
    "#{start} / #{finish}"
  end

  defp fetch_windows(session) do
    case TmuxManager.list_panes(session) do
      {:ok, panes_by_window} ->
        panes_by_window
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(fn idx -> %{index: idx, name: nil} end)

      {:error, _} ->
        []
    end
  end

  defp get_active_window(session) do
    case command_runner().run([
           "display-message",
           "-p",
           "-t",
           session,
           "\#{window_index}"
         ]) do
      {:ok, output} -> String.trim(output)
      {:error, _} -> "0"
    end
  end

  defp command_runner, do: Application.get_env(:tmux_rm, :command_runner)
end
