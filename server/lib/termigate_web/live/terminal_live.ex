defmodule TermigateWeb.TerminalLive do
  use TermigateWeb, :live_view

  alias Termigate.{Config, PaneStream, TmuxManager}

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
  def mount(%{"target" => target}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Termigate.PubSub, "pane:#{target}")
      Phoenix.PubSub.subscribe(Termigate.PubSub, "config")
    end

    channel_token = Phoenix.Token.sign(socket, "channel", %{target: target})
    config = Config.get()
    quick_actions = config["quick_actions"] || []
    terminal_prefs = config["terminal"] || %{}

    # Parse session:window.pane to build back link to multi-pane view
    back_path =
      case Regex.run(~r/^(.+):(\d+)\.\d+$/, target) do
        [_, session, window] -> "/sessions/#{session}/windows/#{window}"
        _ -> "/"
      end

    socket =
      socket
      |> assign(:target, target)
      |> assign(:channel_token, channel_token)
      |> assign(:pane_dead, false)
      |> assign(:page_title, target)
      |> assign(:last_resize_at, 0)
      |> assign(:quick_actions, quick_actions)
      |> assign(:show_actions, true)
      |> assign(:pending_action, nil)
      |> assign(:back_path, back_path)
      |> assign(:terminal_prefs, terminal_prefs)

    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="terminal-page flex flex-col h-dvh bg-black">
      <meta name="channel-token" content={@channel_token} />

      <header class="terminal-header terminal-header-bar">
        <.link
          navigate={@back_path}
          class="text-base-content/50 hover:text-base-content text-sm gap-1"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> <span class="hidden sm:inline">Back</span>
        </.link>
        <span class="text-base-content/70 text-sm font-mono tracking-tight">{@target}</span>
        <div class="flex items-center gap-0.5">
          <button
            class="split-btn text-base-content/40 hover:text-base-content text-sm"
            phx-click="split_pane"
            phx-value-direction="horizontal"
            title="Split horizontally"
            aria-label="Split pane horizontally"
          >
            <svg viewBox="0 0 20 20" fill="currentColor" class="size-5">
              <path d="M2 4.5A2.5 2.5 0 014.5 2h11A2.5 2.5 0 0118 4.5v11a2.5 2.5 0 01-2.5 2.5h-11A2.5 2.5 0 012 15.5v-11zM9 4H4.5A.5.5 0 004 4.5v11a.5.5 0 00.5.5H9V4zm2 12h4.5a.5.5 0 00.5-.5v-11a.5.5 0 00-.5-.5H11v12z"/>
            </svg>
          </button>
          <button
            class="split-btn text-base-content/40 hover:text-base-content text-sm"
            phx-click="split_pane"
            phx-value-direction="vertical"
            title="Split vertically"
            aria-label="Split pane vertically"
          >
            <svg viewBox="0 0 20 20" fill="currentColor" class="size-5">
              <path d="M2 4.5A2.5 2.5 0 014.5 2h11A2.5 2.5 0 0118 4.5v11a2.5 2.5 0 01-2.5 2.5h-11A2.5 2.5 0 012 15.5v-11zM4 9V4.5a.5.5 0 01.5-.5h11a.5.5 0 01.5.5V9H4zm0 2v4.5a.5.5 0 00.5.5h11a.5.5 0 00.5-.5V11H4z"/>
            </svg>
          </button>
          <button
            class="terminal-prefs-btn text-base-content/50 hover:text-base-content text-sm"
            aria-label="Terminal preferences"
          >
            <.icon name="hero-cog-6-tooth-micro" class="size-5" />
          </button>
        </div>
      </header>

      <%!-- Control signal bar --%>
      <div class="control-signal-bar">
        <button class="ctl-btn" phx-click="send_control" phx-value-key="c" title="Send SIGINT (Ctrl+C)">
          <kbd>^C</kbd>
        </button>
        <button class="ctl-btn" phx-click="send_control" phx-value-key="d" title="Send EOF (Ctrl+D)">
          <kbd>^D</kbd>
        </button>
        <button class="ctl-btn" phx-click="send_control" phx-value-key="z" title="Suspend (Ctrl+Z)">
          <kbd>^Z</kbd>
        </button>
        <button class="ctl-btn" phx-click="send_control" phx-value-key="l" title="Clear screen (Ctrl+L)">
          <kbd>^L</kbd>
        </button>
        <button class="ctl-btn ctl-btn-danger" phx-click="send_control" phx-value-key="\\" title="Send SIGQUIT (Ctrl+\\)">
          <kbd>^\</kbd>
        </button>
      </div>

      <%!-- Quick action bar --%>
      <div
        :if={@quick_actions != [] and @show_actions}
        class="terminal-action-bar quick-action-bar"
      >
        <button
          :for={action <- @quick_actions}
          class={"btn btn-xs sm:btn-xs btn-sm #{action_color_class(action)}"}
          phx-click="quick_action"
          phx-value-id={action["id"]}
        >
          <.icon :if={action_icon(action)} name={action_icon(action)} class="size-3" />
          {action["label"]}
          <span :if={action["confirm"]} class="text-warning text-[10px] opacity-70">!</span>
        </button>
        <button class="btn btn-ghost btn-xs ml-auto shrink-0" phx-click="toggle_actions">
          <.icon name="hero-chevron-up-micro" class="size-3" />
        </button>
      </div>

      <div
        :if={@quick_actions != [] and not @show_actions}
        class="terminal-action-bar quick-action-bar py-0.5"
      >
        <button class="btn btn-ghost btn-xs text-base-content/40" phx-click="toggle_actions">
          <.icon name="hero-chevron-down-micro" class="size-3" />
          <span class="text-xs">{length(@quick_actions)} actions</span>
        </button>
      </div>

      <div
        id="terminal"
        phx-hook="TerminalHook"
        phx-update="ignore"
        data-target={@target}
        data-terminal-prefs={Jason.encode!(@terminal_prefs)}
        class="terminal-container flex-1 min-h-0"
      >
      </div>

      <%!-- Pane dead overlay --%>
      <div :if={@pane_dead} class="fixed inset-0 bg-black/80 flex items-center justify-center z-50">
        <div class="text-center text-base-content">
          <.icon name="hero-x-circle" class="size-12 mx-auto mb-4 text-base-content/30" />
          <p class="text-lg font-semibold mb-4">Session ended</p>
          <.link navigate={~p"/"} class="btn btn-primary">
            Back to Sessions
          </.link>
        </div>
      </div>

      <%!-- Quick action confirmation modal --%>
      <.modal
        :if={@pending_action}
        id="action-confirm"
        show={true}
        on_confirm={JS.push("confirm_action")}
        confirm_variant="btn-primary"
      >
        <:title>Run command?</:title>
        <pre class="bg-base-300 text-base-content p-3 rounded-lg text-sm font-mono overflow-x-auto">{@pending_action["command"]}</pre>
        <:confirm>Run</:confirm>
        <:cancel>Cancel</:cancel>
      </.modal>
    </div>
    """
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info({:pane_dead, _target}, socket) do
    {:noreply, assign(socket, :pane_dead, true)}
  end

  def handle_info({:pane_superseded, _old_target, new_target}, socket) do
    {:noreply, push_navigate(socket, to: "/terminal/#{new_target}")}
  end

  def handle_info({:pane_resized, cols, rows}, socket) do
    {:noreply, push_event(socket, "pane_resized", %{cols: cols, rows: rows})}
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

  # Ignore output events — Channel handles these
  def handle_info({:pane_output, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_reconnected, _, _}, socket), do: {:noreply, socket}

  # --- Event handlers ---

  @impl true
  def handle_event("split_pane", %{"direction" => direction}, socket) do
    dir = if direction == "vertical", do: :vertical, else: :horizontal

    case TmuxManager.split_pane(socket.assigns.target, dir) do
      {:ok, _} ->
        {:noreply, push_navigate(socket, to: socket.assigns.back_path)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    cols = to_integer(cols)
    rows = to_integer(rows)

    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_resize_at

    if cols && rows && now - last > 500 do
      PaneStream.resize(socket.assigns.target, cols, rows)
      {:noreply, assign(socket, :last_resize_at, now)}
    else
      {:noreply, socket}
    end
  end

  @control_keys %{
    "c" => "\x03",
    "d" => "\x04",
    "z" => "\x1a",
    "l" => "\x0c",
    "\\" => "\x1c"
  }

  def handle_event("send_control", %{"key" => key}, socket) do
    case Map.get(@control_keys, key) do
      nil ->
        {:noreply, socket}

      char ->
        PaneStream.send_keys(socket.assigns.target, char)
        {:noreply, socket}
    end
  end

  def handle_event("quick_action", %{"id" => id}, socket) do
    action = Enum.find(socket.assigns.quick_actions, &(&1["id"] == id))

    cond do
      is_nil(action) ->
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

  def handle_event("update_terminal_prefs", prefs, socket) when is_map(prefs) do
    Config.update(fn config ->
      Map.put(config, "terminal", prefs)
    end)

    {:noreply, socket}
  end

  # --- Private ---

  defp send_quick_action(socket, action) do
    command = action["command"] <> "\n"
    target = socket.assigns.target

    case PaneStream.send_keys(target, command) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Quick action failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to send command: #{inspect(reason)}")}
    end
  end

  defp action_color_class(action) do
    Map.get(@color_classes, action["color"], "btn-ghost")
  end

  defp action_icon(action) do
    Map.get(@icon_map, action["icon"])
  end

  defp to_integer(val) when is_integer(val), do: val

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_integer(_), do: nil
end
