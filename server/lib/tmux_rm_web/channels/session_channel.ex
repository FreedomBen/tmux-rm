defmodule TmuxRmWeb.SessionChannel do
  @moduledoc """
  Phoenix Channel for session list updates.

  Native clients join this channel to receive real-time session list
  updates. Session mutations go through the REST API, not this channel.
  """
  use Phoenix.Channel

  alias TmuxRm.SessionPoller

  require Logger

  @impl true
  def join("sessions", _params, socket) do
    Phoenix.PubSub.subscribe(TmuxRm.PubSub, "sessions:state")

    sessions = SessionPoller.get()

    socket = assign(socket, :last_sessions, sessions)

    {:ok, %{sessions: serialize_sessions(sessions)}, socket}
  end

  @impl true
  def handle_info({:sessions_updated, sessions}, socket) do
    if sessions != socket.assigns.last_sessions do
      push(socket, "sessions_updated", %{sessions: serialize_sessions(sessions)})
      {:noreply, assign(socket, :last_sessions, sessions)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:tmux_status_changed, status}, socket) do
    push(socket, "tmux_status", %{status: serialize_status(status)})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp serialize_sessions(sessions) do
    Enum.map(sessions, fn session ->
      %{
        name: session.name,
        windows: session.windows,
        created: session.created,
        attached: session.attached?,
        panes: serialize_panes(session)
      }
    end)
  end

  defp serialize_panes(%{panes: panes}) when is_map(panes) do
    panes
    |> Enum.flat_map(fn {_win_idx, pane_list} -> pane_list end)
    |> Enum.map(fn pane ->
      %{
        session_name: pane.session_name,
        window_index: pane.window_index,
        index: pane.index,
        width: pane.width,
        height: pane.height,
        command: pane.command,
        pane_id: pane.pane_id
      }
    end)
  end

  defp serialize_panes(_), do: []

  defp serialize_status(:ok), do: "ok"
  defp serialize_status(:no_server), do: "no_server"
  defp serialize_status(:not_found), do: "not_found"
  defp serialize_status({:error, msg}), do: "error: #{msg}"
  defp serialize_status(other), do: inspect(other)
end
