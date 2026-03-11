defmodule TmuxRmWeb.TerminalLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.PaneStream

  require Logger

  @impl true
  def mount(%{"target" => target}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "pane:#{target}")
    end

    channel_token = Phoenix.Token.sign(socket, "channel", %{target: target})

    socket =
      socket
      |> assign(:target, target)
      |> assign(:channel_token, channel_token)
      |> assign(:pane_dead, false)
      |> assign(:page_title, target)
      |> assign(:last_resize_at, 0)

    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-dvh bg-black">
      <meta name="channel-token" content={@channel_token} />

      <header class="flex items-center justify-between px-4 py-2 bg-gray-900 border-b border-gray-700 shrink-0">
        <.link navigate={~p"/"} class="text-gray-400 hover:text-white text-sm">
          <.icon name="hero-arrow-left-micro" class="size-4 inline" /> Sessions
        </.link>
        <span class="text-gray-300 text-sm font-mono">{@target}</span>
        <.link navigate={~p"/"} class="text-gray-400 hover:text-white text-sm">
          <.icon name="hero-cog-6-tooth-micro" class="size-4" />
        </.link>
      </header>

      <div
        id="terminal"
        phx-hook="TerminalHook"
        phx-update="ignore"
        data-target={@target}
        class="flex-1 min-h-0"
      >
      </div>

      <div :if={@pane_dead} class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
        <div class="text-center text-white">
          <.icon name="hero-x-circle" class="size-12 mx-auto mb-4 text-gray-400" />
          <p class="text-xl mb-4">Session ended</p>
          <.link navigate={~p"/"} class="btn btn-primary">
            Back to Sessions
          </.link>
        </div>
      </div>
    </div>
    """
  end

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

  # Ignore output events — Channel handles these
  def handle_info({:pane_output, _, _}, socket), do: {:noreply, socket}
  def handle_info({:pane_reconnected, _, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    cols = to_integer(cols)
    rows = to_integer(rows)

    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_resize_at

    # Throttle: ignore resizes within 500ms
    if cols && rows && now - last > 500 do
      PaneStream.resize(socket.assigns.target, cols, rows)
      {:noreply, assign(socket, :last_resize_at, now)}
    else
      {:noreply, socket}
    end
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
