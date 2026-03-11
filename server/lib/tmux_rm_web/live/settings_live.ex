defmodule TmuxRmWeb.SettingsLive do
  use TmuxRmWeb, :live_view

  alias TmuxRm.Auth
  alias TmuxRm.Config

  require Logger

  @valid_colors ~w(default green red yellow blue)
  @valid_icons [nil, "rocket", "play", "stop", "trash", "arrow-up", "terminal"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TmuxRm.PubSub, "config")
    end

    config = Config.get()

    socket =
      socket
      |> assign(:quick_actions, config["quick_actions"] || [])
      |> assign(:session_ttl_hours, Auth.session_ttl_hours())
      |> assign(:editing, nil)
      |> assign(:form_data, default_form())
      |> assign(:form_errors, %{})
      |> assign(:page_title, "Settings")

    {:ok, socket}
  end

  @impl true
  def handle_info({:config_changed, config}, socket) do
    ttl = get_in(config, ["auth", "session_ttl_hours"]) || Auth.default_session_ttl_hours()

    {:noreply,
     socket
     |> assign(:quick_actions, config["quick_actions"] || [])
     |> assign(:session_ttl_hours, ttl)}
  end

  @impl true
  def handle_event("new_action", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, :new)
     |> assign(:form_data, default_form())
     |> assign(:form_errors, %{})}
  end

  def handle_event("edit_action", %{"id" => id}, socket) do
    action = Enum.find(socket.assigns.quick_actions, &(&1["id"] == id))

    if action do
      form_data = %{
        "label" => action["label"] || "",
        "command" => action["command"] || "",
        "color" => action["color"] || "default",
        "icon" => action["icon"] || "",
        "confirm" => action["confirm"] || false
      }

      {:noreply,
       socket
       |> assign(:editing, id)
       |> assign(:form_data, form_data)
       |> assign(:form_errors, %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:form_data, default_form())
     |> assign(:form_errors, %{})}
  end

  def handle_event("validate_action", %{"action" => params}, socket) do
    errors = validate_form(params)
    form_data = Map.merge(socket.assigns.form_data, params)
    {:noreply, assign(socket, form_data: form_data, form_errors: errors)}
  end

  def handle_event("save_action", %{"action" => params}, socket) do
    errors = validate_form(params)

    if errors == %{} do
      action = build_action(params, socket.assigns.editing)

      case Config.upsert_action(action) do
        {:ok, _config} ->
          {:noreply,
           socket
           |> assign(:editing, nil)
           |> assign(:form_data, default_form())
           |> assign(:form_errors, %{})
           |> put_flash(:info, "Quick action saved.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  def handle_event("delete_action", %{"id" => id}, socket) do
    case Config.delete_action(id) do
      {:ok, _config} ->
        {:noreply, put_flash(socket, :info, "Quick action deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("move_up", %{"id" => id}, socket) do
    ids = Enum.map(socket.assigns.quick_actions, & &1["id"])

    case Enum.find_index(ids, &(&1 == id)) do
      idx when idx > 0 ->
        ids = swap(ids, idx, idx - 1)
        Config.reorder_actions(ids)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("move_down", %{"id" => id}, socket) do
    ids = Enum.map(socket.assigns.quick_actions, & &1["id"])

    case Enum.find_index(ids, &(&1 == id)) do
      idx when idx < length(ids) - 1 ->
        ids = swap(ids, idx, idx + 1)
        Config.reorder_actions(ids)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_ttl", %{"session_ttl_hours" => hours_str}, socket) do
    case Integer.parse(hours_str) do
      {hours, _} when hours > 0 ->
        case Auth.update_session_ttl(hours) do
          :ok ->
            {:noreply,
             socket
             |> assign(:session_ttl_hours, hours)
             |> put_flash(:info, "Session duration updated.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to update: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid session duration.")}
    end
  end

  def handle_event("reset_config", _params, socket) do
    case Config.reset() do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(:editing, nil)
         |> assign(:form_data, default_form())
         |> assign(:form_errors, %{})
         |> put_flash(:info, "Config reset to defaults.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reset: #{inspect(reason)}")}
    end
  end

  # --- Private ---

  defp default_form do
    %{"label" => "", "command" => "", "color" => "default", "icon" => "", "confirm" => false}
  end

  defp validate_form(params) do
    errors = %{}

    errors =
      if String.trim(params["label"] || "") == "" do
        Map.put(errors, "label", "Label is required")
      else
        errors
      end

    errors =
      if String.trim(params["command"] || "") == "" do
        Map.put(errors, "command", "Command is required")
      else
        if byte_size(params["command"] || "") > 4096 do
          Map.put(errors, "command", "Command too long (max 4096 bytes)")
        else
          errors
        end
      end

    errors
  end

  defp build_action(params, editing) do
    action = %{
      "label" => String.trim(params["label"]),
      "command" => String.trim(params["command"]),
      "color" => if(params["color"] in @valid_colors, do: params["color"], else: "default"),
      "icon" => if(params["icon"] in @valid_icons, do: params["icon"], else: nil),
      "confirm" => params["confirm"] in [true, "true", "on"]
    }

    case editing do
      :new -> action
      id when is_binary(id) -> Map.put(action, "id", id)
      _ -> action
    end
  end

  @badge_classes %{
    "default" => "",
    "green" => "badge-success",
    "red" => "badge-error",
    "yellow" => "badge-warning",
    "blue" => "badge-info"
  }

  defp action_badge_class(color) do
    Map.get(@badge_classes, color, "")
  end

  defp swap(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end
end
