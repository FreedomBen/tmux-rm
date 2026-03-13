defmodule TermigateWeb.MultiPaneLive do
  @moduledoc """
  LiveView showing all panes in a tmux window in a CSS Grid layout.
  Mirrors tmux's split-pane layout with window tabs for navigation.
  Supports maximize/restore per pane.
  """
  use TermigateWeb, :live_view

  alias Termigate.{Config, LayoutPoller, PaneStream, TmuxManager}

  require Logger

  @color_classes %{
    "default" => "btn-ghost",
    "green" => "btn-success",
    "red" => "btn-error",
    "yellow" => "btn-warning",
    "blue" => "btn-info"
  }

  @icon_map %{
    "rocket" => "hero-rocket-launch-micro",
    "play" => "hero-play-micro",
    "stop" => "hero-stop-micro",
    "trash" => "hero-trash-micro",
    "arrow-up" => "hero-arrow-up-micro",
    "terminal" => "hero-command-line-micro"
  }

  @impl true
  def mount(%{"session" => session, "window" => window}, _session, socket) do
    window = to_string(window)

    if connected?(socket) do
      LayoutPoller.subscribe(session, window)
      Phoenix.PubSub.subscribe(Termigate.PubSub, "sessions:state")
      Phoenix.PubSub.subscribe(Termigate.PubSub, "config")
    end

    # Fetch layout and window list
    layout =
      case LayoutPoller.get(session, window) do
        {:ok, panes} -> panes
        {:error, _} -> []
      end

    windows = fetch_windows(session)
    channel_token = Phoenix.Token.sign(socket, "channel", %{session: session})
    config = Config.get()
    quick_actions = config["quick_actions"] || []
    terminal_prefs = config["terminal"] || %{}

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
      |> assign(:active_pane, nil)
      |> assign(:quick_actions, quick_actions)
      |> assign(:show_actions, true)
      |> assign(:pending_action, nil)
      |> assign(:terminal_prefs, terminal_prefs)

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
          <.icon name="hero-arrow-left-micro" class="size-4" />
          <span class="hidden sm:inline">Sessions</span>
        </.link>
        <span class="text-base-content/70 text-sm font-mono tracking-tight">{@session}</span>
        <.link navigate={~p"/settings"} class="text-base-content/50 hover:text-base-content text-sm" aria-label="Settings">
          <.icon name="hero-cog-6-tooth-micro" class="size-5" />
        </.link>
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
          <button
            class="new-window-btn"
            phx-click="create_window"
            title="New window"
          >
            <.icon name="hero-plus-micro" class="size-3.5" />
          </button>
        </div>
      </div>

      <%!-- Control signal bar --%>
      <div class="control-signal-bar">
        <button
          :for={{label, key} <- [{"^C", "c"}, {"^D", "d"}, {"^Z", "z"}, {"^L", "l"}, {"^\\", "\\"}]}
          class={"ctl-btn #{if key == "\\", do: "ctl-btn-danger"}"}
          phx-click="send_control"
          phx-value-key={key}
          disabled={@active_pane == nil}
        >
          <kbd>{label}</kbd>
        </button>
      </div>

      <%!-- Quick action bar --%>
      <div
        :if={@quick_actions != [] and @show_actions}
        class="quick-action-bar"
      >
        <button
          :for={action <- @quick_actions}
          class={"btn btn-xs #{action_color_class(action)} #{if @active_pane == nil, do: "btn-disabled opacity-40"}"}
          disabled={@active_pane == nil}
          phx-click="quick_action"
          phx-value-id={action["id"]}
        >
          <.icon :if={action_icon(action)} name={action_icon(action)} class="size-3" />
          {action["label"]}
          <span :if={action["confirm"]} class="text-warning text-[10px] opacity-70">!</span>
        </button>
        <span
          :if={@active_pane == nil}
          class="text-xs text-base-content/30 ml-1 hidden sm:inline"
        >
          click a pane to activate
        </span>
        <span
          :if={@active_pane}
          class="text-xs text-base-content/30 ml-1 hidden sm:inline font-mono"
        >
          {String.split(@active_pane, ".") |> List.last() |> then(&"pane #{&1}")}
        </span>
        <button class="btn btn-ghost btn-xs ml-auto shrink-0" phx-click="toggle_actions">
          <.icon name="hero-chevron-up-micro" class="size-3" />
        </button>
      </div>

      <div
        :if={@quick_actions != [] and not @show_actions}
        class="quick-action-bar py-0.5"
      >
        <button class="btn btn-ghost btn-xs text-base-content/40" phx-click="toggle_actions">
          <.icon name="hero-chevron-down-micro" class="size-3" />
          <span class="text-xs">{length(@quick_actions)} actions</span>
        </button>
      </div>

      <%!-- Confirm dialog for actions that require confirmation --%>
      <div
        :if={@pending_action}
        class="quick-action-bar items-center justify-between border-b border-warning/20 bg-warning/5"
      >
        <span class="text-xs text-warning">
          Run "<strong>{@pending_action["label"]}</strong>" on pane?
        </span>
        <div class="flex gap-1">
          <button class="btn btn-warning btn-xs" phx-click="confirm_action">Confirm</button>
          <button class="btn btn-ghost btn-xs" phx-click="cancel_action">Cancel</button>
        </div>
      </div>

      <%!-- Multi-pane grid (desktop/tablet) --%>
      <div
        :if={@panes != []}
        id="multi-pane-grid"
        phx-hook="PaneResizeHook"
        class={["flex-1 min-h-0 relative", if(@maximized, do: "grid", else: "hidden sm:grid")]}
        style={"grid-template-columns: #{@grid.cols}; grid-template-rows: #{@grid.rows}; gap: 2px;"}
        data-panes={
          Jason.encode!(
            Enum.map(@panes, fn p ->
              %{target: p.target, left: p.left, top: p.top, width: p.width, height: p.height}
            end)
          )
        }
        data-col-bounds={Jason.encode!(@grid.col_bounds)}
        data-row-bounds={Jason.encode!(@grid.row_bounds)}
        data-maximized={if @maximized, do: "true", else: nil}
      >
        <%= for pane <- @panes do %>
          <div
            id={"pane-wrapper-#{pane.target}"}
            class={[
              "relative group min-h-0 overflow-hidden",
              if(@maximized == pane.target,
                do: "pane-maximized",
                else:
                  if(@active_pane == pane.target,
                    do: "border border-primary/40",
                    else: "border border-base-content/5"
                  )
              )
            ]}
            style={
              if @maximized == nil or @maximized == pane.target do
                if @maximized == pane.target do
                  ""
                else
                  "grid-column: #{pane_grid_col(pane, @grid)}; grid-row: #{pane_grid_row(pane, @grid)};"
                end
              else
                "display: none;"
              end
            }
          >
            <div
              id={"pane-#{pane.target}"}
              phx-hook="TerminalHook"
              phx-update="ignore"
              data-target={pane.target}
              data-mode="multi"
              data-cols={to_string(pane.width)}
              data-rows={to_string(pane.height)}
              data-terminal-prefs={Jason.encode!(@terminal_prefs)}
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
              <button
                class="pane-overlay-btn"
                phx-click="split_pane"
                phx-value-target={pane.target}
                phx-value-direction="horizontal"
                title="Split horizontally"
              >
                <svg viewBox="0 0 20 20" fill="currentColor" class="size-4">
                  <path d="M2 4.5A2.5 2.5 0 014.5 2h11A2.5 2.5 0 0118 4.5v11a2.5 2.5 0 01-2.5 2.5h-11A2.5 2.5 0 012 15.5v-11zM9 4H4.5A.5.5 0 004 4.5v11a.5.5 0 00.5.5H9V4zm2 12h4.5a.5.5 0 00.5-.5v-11a.5.5 0 00-.5-.5H11v12z" />
                </svg>
              </button>
              <button
                class="pane-overlay-btn"
                phx-click="split_pane"
                phx-value-target={pane.target}
                phx-value-direction="vertical"
                title="Split vertically"
              >
                <svg viewBox="0 0 20 20" fill="currentColor" class="size-4">
                  <path d="M2 4.5A2.5 2.5 0 014.5 2h11A2.5 2.5 0 0118 4.5v11a2.5 2.5 0 01-2.5 2.5h-11A2.5 2.5 0 012 15.5v-11zM4 9V4.5a.5.5 0 01.5-.5h11a.5.5 0 01.5.5V9H4zm0 2v4.5a.5.5 0 00.5.5h11a.5.5 0 00.5-.5V11H4z" />
                </svg>
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Divider overlay — children managed by PaneResizeHook JS --%>
        <div
          id="pane-dividers"
          phx-update="ignore"
          class="absolute inset-0 pointer-events-none"
          style="z-index: 3;"
        >
        </div>
      </div>

      <%!-- Mobile pane list — tappable cards maximize the pane --%>
      <div :if={@panes != [] and @maximized == nil} class="flex-1 overflow-y-auto sm:hidden p-3 space-y-2">
        <div
          :for={pane <- @panes}
          class="pane-row rounded-xl mobile-pane-card cursor-pointer"
          phx-click="maximize_pane"
          phx-value-target={pane.target}
        >
          <.icon name="hero-command-line-micro" class="size-4 text-base-content/25 shrink-0" />
          <div class="flex-1 min-w-0">
            <div class="text-sm font-mono text-base-content/70">{pane.target}</div>
            <div class="text-xs text-base-content/40 mt-0.5">
              {pane.command} &middot; {pane.width}&times;{pane.height}
            </div>
          </div>
          <.icon name="hero-arrows-pointing-out-micro" class="size-4 text-base-content/20 shrink-0" />
        </div>
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

    # Push resize events to terminals whose dimensions changed
    old_panes = socket.assigns.panes

    socket =
      Enum.reduce(panes, socket, fn pane, acc ->
        old = Enum.find(old_panes, &(&1.target == pane.target))

        if old && (old.width != pane.width || old.height != pane.height) do
          push_event(acc, "pane_resized", %{
            target: pane.target,
            cols: pane.width,
            rows: pane.height
          })
        else
          acc
        end
      end)

    # If the active pane no longer exists, clear it
    active_pane =
      if socket.assigns.active_pane &&
           not Enum.any?(panes, &(&1.target == socket.assigns.active_pane)) do
        nil
      else
        socket.assigns.active_pane
      end

    {:noreply, assign(socket, panes: panes, grid: grid, maximized: maximized, active_pane: active_pane)}
  end

  def handle_info({:sessions_updated, _sessions}, socket) do
    windows = fetch_windows(socket.assigns.session)
    {:noreply, assign(socket, :windows, windows)}
  end

  def handle_info({:config_changed, config}, socket) do
    terminal_prefs = config["terminal"] || %{}

    socket =
      socket
      |> assign(:quick_actions, config["quick_actions"] || [])
      |> assign(:terminal_prefs, terminal_prefs)
      |> push_event("terminal_prefs", terminal_prefs)

    {:noreply, socket}
  end

  # Ignore pane output/control events — each TerminalHook handles its own via Channel
  def handle_info({:pane_output, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_dead, _}, socket), do: {:noreply, socket}
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

  def handle_event("pane_focused", %{"target" => target}, socket) do
    {:noreply, assign(socket, :active_pane, target)}
  end

  @control_keys %{
    "c" => "\x03",
    "d" => "\x04",
    "z" => "\x1a",
    "l" => "\x0c",
    "\\" => "\x1c"
  }

  def handle_event("send_control", %{"key" => key}, socket) do
    case {Map.get(@control_keys, key), socket.assigns.active_pane} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {char, target} ->
        PaneStream.send_keys(target, char)
        {:noreply, socket}
    end
  end

  def handle_event("quick_action", params, socket) do
    id = params["id"] || params["value"]
    action = if id, do: Enum.find(socket.assigns.quick_actions, &(&1["id"] == id))

    cond do
      is_nil(action) || is_nil(socket.assigns.active_pane) ->
        {:noreply, socket}

      action["confirm"] ->
        {:noreply, assign(socket, :pending_action, action)}

      true ->
        send_quick_action(socket, action)
    end
  end

  def handle_event("confirm_action", _params, socket) do
    case socket.assigns.pending_action do
      nil ->
        {:noreply, socket}

      action ->
        socket = assign(socket, :pending_action, nil)
        send_quick_action(socket, action)
    end
  end

  def handle_event("cancel_action", _params, socket) do
    {:noreply, assign(socket, :pending_action, nil)}
  end

  def handle_event("toggle_actions", _params, socket) do
    {:noreply, assign(socket, :show_actions, !socket.assigns.show_actions)}
  end

  def handle_event("create_window", _params, socket) do
    session = socket.assigns.session

    case TmuxManager.create_window(session) do
      :ok ->
        # Fetch updated window list and navigate to the new (last) window
        windows = fetch_windows(session)
        new_window = windows |> List.last()

        socket =
          socket
          |> assign(:windows, windows)
          |> push_navigate(to: "/sessions/#{session}/windows/#{new_window.index}")

        {:noreply, socket}

      {:error, _msg} ->
        {:noreply, socket}
    end
  end

  def handle_event("split_pane", %{"target" => target, "direction" => direction}, socket) do
    dir = if direction == "vertical", do: :vertical, else: :horizontal
    TmuxManager.split_pane(target, dir)
    {:noreply, socket}
  end

  def handle_event(
        "resize_pane_drag",
        %{"target" => target, "axis" => axis, "delta" => delta},
        socket
      ) do
    pane = Enum.find(socket.assigns.panes, &(&1.target == target))

    if pane && delta != 0 do
      case axis do
        "x" -> TmuxManager.resize_pane(target, x: max(pane.width + delta, 2))
        "y" -> TmuxManager.resize_pane(target, y: max(pane.height + delta, 2))
        _ -> :ok
      end
    end

    {:noreply, socket}
  end

  def handle_event("resize", _params, socket) do
    # Multi-pane view is passive — ignore resize events
    {:noreply, socket}
  end

  def handle_event("update_terminal_prefs", prefs, socket) when is_map(prefs) do
    Config.update(fn config ->
      Map.put(config, "terminal", prefs)
    end)

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

  defp command_runner, do: Application.get_env(:termigate, :command_runner)

  defp send_quick_action(socket, action) do
    command = action["command"] <> "\n"
    target = socket.assigns.active_pane

    case PaneStream.send_keys(target, command) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Quick action failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp action_color_class(action) do
    Map.get(@color_classes, action["color"], "btn-ghost")
  end

  defp action_icon(action) do
    Map.get(@icon_map, action["icon"])
  end
end
