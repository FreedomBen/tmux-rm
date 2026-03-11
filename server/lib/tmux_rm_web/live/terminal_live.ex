defmodule TmuxRmWeb.TerminalLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.{Config, PaneStream}

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
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "pane:#{target}")
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "config")
    end

    channel_token = Phoenix.Token.sign(socket, "channel", %{target: target})
    config = Config.get()
    quick_actions = config["quick_actions"] || []

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

    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="terminal-page flex flex-col h-dvh bg-black">
      <meta name="channel-token" content={@channel_token} />

      <header class="terminal-header flex items-center justify-between px-4 py-2 bg-gray-900 border-b border-gray-700 shrink-0 transition-transform duration-300 sm:translate-y-0 z-30">
        <.link
          navigate={~p"/"}
          class="text-gray-400 hover:text-white text-sm min-h-[48px] sm:min-h-0 flex items-center"
        >
          <.icon name="hero-arrow-left-micro" class="size-4 inline" /> Sessions
        </.link>
        <span class="text-gray-300 text-sm font-mono">{@target}</span>
        <button
          class="terminal-prefs-btn text-gray-400 hover:text-white text-sm min-h-[48px] sm:min-h-0 flex items-center"
          aria-label="Terminal preferences"
        >
          <.icon name="hero-cog-6-tooth-micro" class="size-4" />
        </button>
      </header>

      <%!-- Quick action bar --%>
      <div
        :if={@quick_actions != [] and @show_actions}
        class="terminal-action-bar flex items-center gap-2 px-3 py-1.5 bg-gray-900/80 border-b border-gray-700/50 overflow-x-auto shrink-0 transition-all duration-300 sm:translate-y-0 sm:opacity-100 z-20"
        style="scroll-snap-type: x mandatory;"
      >
        <button
          :for={action <- @quick_actions}
          class={"btn btn-xs sm:btn-xs btn-sm #{action_color_class(action)}"}
          style="scroll-snap-align: start;"
          phx-click="quick_action"
          phx-value-id={action["id"]}
        >
          <.icon :if={action_icon(action)} name={action_icon(action)} class="size-3" />
          {action["label"]}
          <span :if={action["confirm"]} class="text-warning text-[10px]">⚠</span>
        </button>
        <button class="btn btn-ghost btn-xs ml-auto" phx-click="toggle_actions">
          <.icon name="hero-chevron-up-micro" class="size-3" />
        </button>
      </div>

      <div
        :if={@quick_actions != [] and not @show_actions}
        class="terminal-action-bar flex items-center px-3 py-0.5 bg-gray-900/80 border-b border-gray-700/50 shrink-0 transition-all duration-300 sm:translate-y-0 sm:opacity-100 z-20"
      >
        <button class="btn btn-ghost btn-xs text-gray-500" phx-click="toggle_actions">
          <.icon name="hero-chevron-down-micro" class="size-3" />
          <span class="text-xs">{length(@quick_actions)} actions</span>
        </button>
      </div>

      <div
        id="terminal"
        phx-hook="TerminalHook"
        phx-update="ignore"
        data-target={@target}
        class="terminal-container flex-1 min-h-0"
      >
      </div>

      <%!-- Pane dead overlay --%>
      <div :if={@pane_dead} class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
        <div class="text-center text-white">
          <.icon name="hero-x-circle" class="size-12 mx-auto mb-4 text-gray-400" />
          <p class="text-xl mb-4">Session ended</p>
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
        <pre class="bg-gray-800 text-gray-200 p-3 rounded text-sm font-mono overflow-x-auto">{@pending_action["command"]}</pre>
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
    {:noreply, assign(socket, :quick_actions, config["quick_actions"] || [])}
  end

  # Ignore output events — Channel handles these
  def handle_info({:pane_output, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_reconnected, _, _}, socket), do: {:noreply, socket}

  # --- Event handlers ---

  @impl true
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
