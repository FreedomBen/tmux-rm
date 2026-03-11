defmodule TmuxRmWeb.SessionListLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.{SessionPoller, TmuxManager}

  require Logger

  @state_topic "sessions:state"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, @state_topic)
    end

    sessions = SessionPoller.get()
    tmux_status = SessionPoller.tmux_status()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:tmux_status, tmux_status)
      |> assign(:expanded, MapSet.new())
      |> assign(:show_new_session_form, false)
      |> assign(:new_session_name, "")
      |> assign(:new_session_error, nil)
      |> assign(:rename_session, nil)
      |> assign(:rename_value, "")
      |> assign(:rename_error, nil)
      |> assign(:confirm_action, nil)
      |> assign(:confirm_message, nil)
      |> assign(:confirm_target, nil)

    {:ok, socket}
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info({:sessions_updated, sessions}, socket) do
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info({:tmux_status_changed, status}, socket) do
    {:noreply, assign(socket, :tmux_status, status)}
  end

  # --- Event handlers ---

  @impl true
  def handle_event("toggle_session", %{"name" => name}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, name) do
        MapSet.delete(socket.assigns.expanded, name)
      else
        MapSet.put(socket.assigns.expanded, name)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("toggle_new_session_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_session_form, !socket.assigns.show_new_session_form)
     |> assign(:new_session_name, "")
     |> assign(:new_session_error, nil)}
  end

  def handle_event("validate_session_name", %{"name" => name}, socket) do
    error =
      cond do
        name == "" ->
          nil

        not TmuxManager.valid_session_name?(name) ->
          "Invalid name. Use only letters, numbers, hyphens, and underscores."

        true ->
          nil
      end

    {:noreply,
     socket
     |> assign(:new_session_name, name)
     |> assign(:new_session_error, error)}
  end

  def handle_event("create_session", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, :new_session_error, "Session name is required.")}
    else
      case TmuxManager.create_session(name) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_new_session_form, false)
           |> assign(:new_session_name, "")
           |> assign(:new_session_error, nil)
           |> put_flash(:info, "Session \"#{name}\" created.")}

        {:error, :invalid_name} ->
          {:noreply, assign(socket, :new_session_error, "Invalid session name.")}

        {:error, msg} ->
          {:noreply, assign(socket, :new_session_error, "Failed: #{msg}")}
      end
    end
  end

  # --- Confirmation dialog flow ---

  def handle_event("request_kill_session", %{"name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:confirm_action, :kill_session)
     |> assign(:confirm_target, name)
     |> assign(
       :confirm_message,
       "Kill session \"#{name}\"? This will terminate all processes in the session."
     )}
  end

  def handle_event("request_kill_pane", %{"target" => target, "pane-count" => count_str}, socket) do
    count = String.to_integer(count_str)

    message =
      if count <= 1 do
        "This is the last pane in the session. Killing it will end the session. Continue?"
      else
        "Kill this pane? The process inside will be terminated."
      end

    {:noreply,
     socket
     |> assign(:confirm_action, :kill_pane)
     |> assign(:confirm_target, target)
     |> assign(:confirm_message, message)}
  end

  def handle_event("confirm_action", _params, socket) do
    socket = execute_confirmed_action(socket)

    {:noreply,
     socket
     |> assign(:confirm_action, nil)
     |> assign(:confirm_target, nil)
     |> assign(:confirm_message, nil)}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_action, nil)
     |> assign(:confirm_target, nil)
     |> assign(:confirm_message, nil)}
  end

  # Legacy handler kept for direct kill (backwards compat)
  def handle_event("kill_session", %{"name" => name}, socket) do
    case TmuxManager.kill_session(name) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Session \"#{name}\" killed.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Failed to kill session: #{msg}")}
    end
  end

  # --- Rename session ---

  def handle_event("start_rename", %{"name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:rename_session, name)
     |> assign(:rename_value, name)
     |> assign(:rename_error, nil)}
  end

  def handle_event("validate_rename", %{"name" => name}, socket) do
    error =
      cond do
        name == "" ->
          "Name cannot be empty."

        not TmuxManager.valid_session_name?(name) ->
          "Invalid name. Use only letters, numbers, hyphens, and underscores."

        true ->
          nil
      end

    {:noreply,
     socket
     |> assign(:rename_value, name)
     |> assign(:rename_error, error)}
  end

  def handle_event("submit_rename", %{"name" => new_name}, socket) do
    old_name = socket.assigns.rename_session
    new_name = String.trim(new_name)

    if old_name == new_name do
      {:noreply, assign(socket, :rename_session, nil)}
    else
      case TmuxManager.rename_session(old_name, new_name) do
        :ok ->
          {:noreply,
           socket
           |> assign(:rename_session, nil)
           |> assign(:rename_value, "")
           |> assign(:rename_error, nil)
           |> put_flash(:info, "Session renamed to \"#{new_name}\".")}

        {:error, :invalid_name} ->
          {:noreply, assign(socket, :rename_error, "Invalid session name.")}

        {:error, reason} ->
          {:noreply, assign(socket, :rename_error, "Rename failed: #{reason}")}
      end
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply,
     socket
     |> assign(:rename_session, nil)
     |> assign(:rename_value, "")
     |> assign(:rename_error, nil)}
  end

  # --- Window and pane management ---

  def handle_event("create_window", %{"session" => session}, socket) do
    case TmuxManager.create_window(session) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Window created in \"#{session}\".")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Failed to create window: #{msg}")}
    end
  end

  def handle_event("split_pane", %{"target" => target, "direction" => dir}, socket) do
    direction = String.to_existing_atom(dir)

    case TmuxManager.split_pane(target, direction) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Pane split.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Failed to split pane: #{msg}")}
    end
  end

  def handle_event("retry_tmux", _params, socket) do
    SessionPoller.force_poll()
    {:noreply, socket}
  end

  # --- Helpers ---

  defp execute_confirmed_action(
         %{assigns: %{confirm_action: :kill_session, confirm_target: name}} = socket
       ) do
    case TmuxManager.kill_session(name) do
      :ok -> put_flash(socket, :info, "Session \"#{name}\" killed.")
      {:error, msg} -> put_flash(socket, :error, "Failed to kill session: #{msg}")
    end
  end

  defp execute_confirmed_action(
         %{assigns: %{confirm_action: :kill_pane, confirm_target: target}} = socket
       ) do
    case TmuxManager.kill_pane(target) do
      :ok -> put_flash(socket, :info, "Pane killed.")
      {:error, msg} -> put_flash(socket, :error, "Failed to kill pane: #{msg}")
    end
  end

  defp execute_confirmed_action(socket), do: socket

  defp session_expanded?(expanded, name), do: MapSet.member?(expanded, name)

  defp format_created(nil), do: ""

  defp format_created(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp total_panes(session) do
    session
    |> Map.get(:panes, %{})
    |> Enum.reduce(0, fn {_window, panes}, acc -> acc + length(panes) end)
  end

  defp sorted_panes(session) do
    session
    |> Map.get(:panes, %{})
    |> Enum.sort_by(fn {window_idx, _} -> window_idx end)
    |> Enum.flat_map(fn {_window_idx, panes} ->
      Enum.sort_by(panes, & &1.index)
    end)
  end
end
