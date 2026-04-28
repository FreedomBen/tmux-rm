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

    notification_config = config["notifications"] || %{}

    # Subscribe to per-pane topics for notification events
    pane_targets = Enum.map(layout, & &1.target)

    subscribed_panes =
      if connected?(socket) do
        for target <- pane_targets do
          Phoenix.PubSub.subscribe(Termigate.PubSub, "pane:#{target}")
        end

        MapSet.new(pane_targets)
      else
        MapSet.new()
      end

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
      |> assign(:quick_actions_enabled, config["quick_actions_enabled"] != false)
      |> assign(:show_actions, true)
      |> assign(:pending_action, nil)
      |> assign(:pending_close_window, nil)
      |> assign(:terminal_prefs, terminal_prefs)
      |> assign(:notification_config, notification_config)
      |> assign(:subscribed_panes, subscribed_panes)

    socket = if connected?(socket), do: push_notification_config(socket), else: socket

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
    <div class="flex flex-col h-dvh bg-black overflow-x-hidden">
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
        <div class="flex items-center gap-3">
          <button
            type="button"
            id="mobile-keyboard-toggle"
            class="text-base-content/50 hover:text-base-content text-sm tooltip tooltip-bottom"
            aria-label="Toggle on-screen keyboard"
            data-tip="Toggle on-screen keyboard"
          >
            <.icon name="hero-command-line-micro" class="kb-icon-on size-5" />
            <.icon name="hero-no-symbol-micro" class="kb-icon-off size-5 hidden text-red-400" />
          </button>
          <.link
            navigate={~p"/settings"}
            class="text-base-content/50 hover:text-base-content text-sm tooltip tooltip-left"
            aria-label="Settings"
            data-tip="Settings"
          >
            <.icon name="hero-cog-6-tooth-micro" class="size-5" />
          </.link>
        </div>
      </div>

      <%!-- Window tabs + control signal bar (collapsible) --%>
      <div class="bars-group" id="bars-group">
        <button
          type="button"
          id="bars-toggle-btn"
          class="bars-toggle-btn tooltip tooltip-bottom"
          aria-label="Toggle tab and control bar"
          data-tip="Collapse/expand tabs and controls"
        >
          <.icon name="hero-chevron-up-micro" class="bars-chevron-up size-3" />
          <.icon name="hero-chevron-down-micro" class="bars-chevron-down size-3 hidden" />
        </button>
        <%!-- Window tabs --%>
        <div class="window-tabs">
          <div class="flex items-center gap-0.5 px-2 flex-1">
            <div :for={win <- @windows} class="window-tab-wrapper">
              <.link
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
                class="window-close-btn tooltip tooltip-bottom"
                phx-click="close_window"
                phx-value-window={win.index}
                onmousedown="event.preventDefault()"
                data-tip="Close window"
                aria-label="Close window"
              >
                &times;
              </button>
            </div>
            <button
              class="new-window-btn tooltip tooltip-bottom"
              phx-click="create_window"
              data-tip="New window"
              aria-label="New window"
            >
              <.icon name="hero-plus-micro" class="size-3.5" />
            </button>
          </div>
        </div>

        <%!-- Control signal bar (mobile/tablet only) --%>
        <div class="control-signal-bar">
          <div class="ctl-group">
            <button
              :for={
                {label, key} <- [{"^C", "c"}, {"^D", "d"}, {"^Z", "z"}, {"^L", "l"}, {"^\\", "\\"}]
              }
              class={"ctl-btn #{if key == "\\", do: "ctl-btn-danger"}"}
              phx-click="send_control"
              phx-value-key={key}
              disabled={@active_pane == nil}
              onmousedown="event.preventDefault()"
            >
              <kbd>{label}</kbd>
            </button>
          </div>

          <span class="ctl-separator">|</span>

          <div class="ctl-group">
            <button
              :for={
                {label, key} <- [
                  {"Tab", "tab"},
                  {raw("&#x2191;"), "up"},
                  {raw("&#x2193;"), "down"},
                  {raw("&#x2190;"), "left"},
                  {raw("&#x2192;"), "right"}
                ]
              }
              class="ctl-btn"
              phx-click="send_special_key"
              phx-value-key={key}
              disabled={@active_pane == nil}
              onmousedown="event.preventDefault()"
            >
              <kbd>{label}</kbd>
            </button>
          </div>
        </div>
      </div>

      <%!-- Quick action bar --%>
      <div
        :if={@quick_actions_enabled and @quick_actions != [] and @show_actions}
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
        <button
          class="btn btn-ghost btn-xs ml-auto shrink-0"
          phx-click="toggle_actions"
          aria-label="Hide quick actions"
        >
          <.icon name="hero-chevron-up-micro" class="size-3" />
        </button>
      </div>

      <div
        :if={@quick_actions_enabled and @quick_actions != [] and not @show_actions}
        class="quick-action-bar py-0.5"
      >
        <button
          class="btn btn-ghost btn-xs text-base-content/40"
          phx-click="toggle_actions"
          aria-label="Show quick actions"
        >
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

      <%!-- Confirm dialog for closing a window --%>
      <div
        :if={@pending_close_window}
        class="quick-action-bar items-center justify-between border-b border-error/20 bg-error/5"
      >
        <span class="text-xs text-error">
          Close window <strong>{@pending_close_window}</strong> and kill all its panes?
        </span>
        <div class="flex gap-1">
          <button class="btn btn-error btn-xs" phx-click="confirm_close_window">Close</button>
          <button class="btn btn-ghost btn-xs" phx-click="cancel_close_window">Cancel</button>
        </div>
      </div>

      <%!-- Multi-pane grid (desktop/tablet) --%>
      <div
        :if={@panes != []}
        id="multi-pane-grid"
        phx-hook="PaneResizeHook"
        class={["flex-1 min-h-0 relative", if(@maximized, do: "grid", else: "hidden sm:grid")]}
        style={"grid-template-columns: #{@grid.cols}; grid-template-rows: #{@grid.rows}; gap: 1px;"}
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
                    do: "border border-primary/50",
                    else: "border border-base-content/15"
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
                  id={"restore-or-fit-#{pane.target}"}
                  class="pane-overlay-btn tooltip tooltip-bottom"
                  phx-hook="RestoreOrFitHook"
                  data-target={pane.target}
                  data-tip="Restore (mobile: fit to screen width)"
                  aria-label="Restore"
                >
                  <.icon name="hero-arrows-pointing-in-micro" class="size-4" />
                </button>
              <% else %>
                <button
                  class="pane-overlay-btn tooltip tooltip-bottom"
                  phx-click="maximize_pane"
                  phx-value-target={pane.target}
                  data-tip="Maximize"
                  aria-label="Maximize"
                >
                  <.icon name="hero-arrows-pointing-out-micro" class="size-4" />
                </button>
              <% end %>
              <button
                class="pane-overlay-btn tooltip tooltip-bottom"
                phx-click="split_pane"
                phx-value-target={pane.target}
                phx-value-direction="horizontal"
                data-tip="Split horizontally"
                aria-label="Split horizontally"
              >
                <svg viewBox="0 0 20 20" fill="currentColor" class="size-4">
                  <path d="M2 4.5A2.5 2.5 0 014.5 2h11A2.5 2.5 0 0118 4.5v11a2.5 2.5 0 01-2.5 2.5h-11A2.5 2.5 0 012 15.5v-11zM9 4H4.5A.5.5 0 004 4.5v11a.5.5 0 00.5.5H9V4zm2 12h4.5a.5.5 0 00.5-.5v-11a.5.5 0 00-.5-.5H11v12z" />
                </svg>
              </button>
              <button
                class="pane-overlay-btn tooltip tooltip-bottom"
                phx-click="split_pane"
                phx-value-target={pane.target}
                phx-value-direction="vertical"
                data-tip="Split vertically"
                aria-label="Split vertically"
              >
                <svg viewBox="0 0 20 20" fill="currentColor" class="size-4">
                  <path d="M2 4.5A2.5 2.5 0 014.5 2h11A2.5 2.5 0 0118 4.5v11a2.5 2.5 0 01-2.5 2.5h-11A2.5 2.5 0 012 15.5v-11zM4 9V4.5a.5.5 0 01.5-.5h11a.5.5 0 01.5.5V9H4zm0 2v4.5a.5.5 0 00.5.5h11a.5.5 0 00.5-.5V11H4z" />
                </svg>
              </button>
              <%= if length(@panes) > 1 and @maximized == nil do %>
                <span class="pane-overlay-separator"></span>
                <button
                  class="pane-overlay-btn tooltip tooltip-bottom"
                  phx-click="equalize_panes"
                  phx-value-direction="horizontal"
                  data-tip="Equal widths"
                  aria-label="Equal widths"
                >
                  <svg viewBox="0 0 16 16" fill="currentColor" class="size-4">
                    <path d="M1 2.5A1.5 1.5 0 012.5 1h4A1.5 1.5 0 018 2.5v11A1.5 1.5 0 016.5 15h-4A1.5 1.5 0 011 13.5v-11zM2.5 2a.5.5 0 00-.5.5v11a.5.5 0 00.5.5h4a.5.5 0 00.5-.5v-11a.5.5 0 00-.5-.5h-4zM9.5 1A1.5 1.5 0 008 2.5v11A1.5 1.5 0 009.5 15h4a1.5 1.5 0 001.5-1.5v-11A1.5 1.5 0 0013.5 1h-4zM9 2.5a.5.5 0 01.5-.5h4a.5.5 0 01.5.5v11a.5.5 0 01-.5.5h-4a.5.5 0 01-.5-.5v-11z" />
                  </svg>
                </button>
                <button
                  class="pane-overlay-btn tooltip tooltip-bottom"
                  phx-click="equalize_panes"
                  phx-value-direction="vertical"
                  data-tip="Equal heights"
                  aria-label="Equal heights"
                >
                  <svg viewBox="0 0 16 16" fill="currentColor" class="size-4">
                    <path d="M2.5 1A1.5 1.5 0 001 2.5v4A1.5 1.5 0 002.5 8h11A1.5 1.5 0 0015 6.5v-4A1.5 1.5 0 0013.5 1h-11zM2 2.5a.5.5 0 01.5-.5h11a.5.5 0 01.5.5v4a.5.5 0 01-.5.5h-11a.5.5 0 01-.5-.5v-4zM1 9.5A1.5 1.5 0 012.5 8h11A1.5 1.5 0 0115 9.5v4a1.5 1.5 0 01-1.5 1.5h-11A1.5 1.5 0 011 13.5v-4zM2.5 9a.5.5 0 00-.5.5v4a.5.5 0 00.5.5h11a.5.5 0 00.5-.5v-4a.5.5 0 00-.5-.5h-11z" />
                  </svg>
                </button>
              <% end %>
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
      <div
        :if={@panes != [] and @maximized == nil}
        class="flex-1 overflow-y-auto sm:hidden p-3 space-y-2"
      >
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

      <%!-- Notification hook (invisible, one per LiveView) --%>
      <div id="notification-hook" phx-hook="NotificationHook" class="hidden" />
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

    # Manage per-pane PubSub subscriptions for notifications
    new_targets = MapSet.new(Enum.map(panes, & &1.target))
    old_targets = socket.assigns.subscribed_panes

    for target <- MapSet.difference(new_targets, old_targets) do
      Phoenix.PubSub.subscribe(Termigate.PubSub, "pane:#{target}")
    end

    for target <- MapSet.difference(old_targets, new_targets) do
      Phoenix.PubSub.unsubscribe(Termigate.PubSub, "pane:#{target}")
    end

    {:noreply,
     assign(socket,
       panes: panes,
       grid: grid,
       maximized: maximized,
       active_pane: active_pane,
       subscribed_panes: new_targets
     )}
  end

  def handle_info({:sessions_updated, _sessions}, socket) do
    windows = fetch_windows(socket.assigns.session)
    {:noreply, assign(socket, :windows, windows)}
  end

  def handle_info({:config_changed, config}, socket) do
    terminal_prefs = config["terminal"] || %{}
    notification_config = config["notifications"] || %{}

    socket =
      socket
      |> assign(:quick_actions, config["quick_actions"] || [])
      |> assign(:quick_actions_enabled, config["quick_actions_enabled"] != false)
      |> assign(:terminal_prefs, terminal_prefs)
      |> assign(:notification_config, notification_config)
      |> push_event("terminal_prefs", terminal_prefs)
      |> push_notification_config()

    {:noreply, socket}
  end

  # Notification events from PaneStream
  def handle_info({:pane_idle, target, idle_ms}, socket) do
    if socket.assigns.notification_config["mode"] == "activity" do
      {:noreply,
       push_event(socket, "notify_pane_idle", %{
         pane: target,
         idle_seconds: div(idle_ms, 1000)
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:command_finished, target, metadata}, socket) do
    if socket.assigns.notification_config["mode"] == "shell" do
      {:noreply,
       push_event(socket, "notify_command_done", %{
         pane: target,
         exit_code: metadata.exit_code,
         command: metadata.command,
         duration_seconds: metadata.duration_seconds
       })}
    else
      {:noreply, socket}
    end
  end

  # Ignore pane output/control events — each TerminalHook handles its own via Channel
  def handle_info({:pane_output, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_dead, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_reconnected, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_resized, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_superseded, _, _}, socket), do: {:noreply, socket}
  def handle_info({:tmux_status_changed, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Event handlers ---

  @impl true
  def handle_event("maximize_pane", %{"target" => target}, socket) do
    socket =
      socket
      |> assign(:maximized, target)
      |> push_event("pane_maximized", %{target: target})

    {:noreply, socket}
  end

  def handle_event("restore_pane", _params, socket) do
    {:noreply, assign(socket, :maximized, nil)}
  end

  def handle_event("fit_pane_width", %{"target" => target, "cols" => cols}, socket) do
    cols = cols |> to_string() |> String.to_integer()
    TmuxManager.resize_pane(target, x: max(cols, 2))
    {:noreply, socket}
  end

  def handle_event("pane_focused", %{"target" => target}, socket) do
    {:noreply, assign(socket, :active_pane, target)}
  end

  def handle_event("focus_pane", %{"pane" => pane_target}, socket) do
    # If maximized on a different pane, unmaximize first
    socket =
      if socket.assigns.maximized && socket.assigns.maximized != pane_target do
        assign(socket, maximized: nil)
      else
        socket
      end

    {:noreply,
     assign(socket, active_pane: pane_target)
     |> push_event("focus_terminal", %{pane: pane_target})}
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

  @special_keys %{
    "tab" => "\t",
    "up" => "\e[A",
    "down" => "\e[B",
    "right" => "\e[C",
    "left" => "\e[D"
  }

  def handle_event("send_special_key", %{"key" => key}, socket) do
    case {Map.get(@special_keys, key), socket.assigns.active_pane} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {seq, target} ->
        PaneStream.send_keys(target, seq)
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

  def handle_event("close_window", %{"window" => window_index}, socket) do
    {:noreply, assign(socket, :pending_close_window, window_index)}
  end

  def handle_event("confirm_close_window", _params, socket) do
    session = socket.assigns.session
    window_index = socket.assigns.pending_close_window

    socket = assign(socket, :pending_close_window, nil)

    case TmuxManager.kill_window(session, window_index) do
      :ok ->
        windows = fetch_windows(session)

        if windows == [] do
          {:noreply, push_navigate(socket, to: "/")}
        else
          first = List.first(windows)
          {:noreply, push_navigate(socket, to: "/sessions/#{session}/windows/#{first.index}")}
        end

      {:error, _msg} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_close_window", _params, socket) do
    {:noreply, assign(socket, :pending_close_window, nil)}
  end

  def handle_event("equalize_panes", %{"direction" => direction}, socket) do
    # Use the session:window as target so tmux applies layout to the whole window
    target = "#{socket.assigns.session}:#{socket.assigns.window}"
    dir = if direction == "vertical", do: :vertical, else: :horizontal
    TmuxManager.equalize_panes(target, dir)
    {:noreply, socket}
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

    for target <- socket.assigns[:subscribed_panes] || [] do
      Phoenix.PubSub.unsubscribe(Termigate.PubSub, "pane:#{target}")
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

  defp push_notification_config(socket) do
    push_event(socket, "notification_config", %{config: socket.assigns.notification_config})
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
