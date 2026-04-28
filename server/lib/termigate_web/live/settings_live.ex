defmodule TermigateWeb.SettingsLive do
  use TermigateWeb, :live_view

  alias Termigate.Auth
  alias Termigate.Config

  require Logger

  @valid_colors ~w(default green red yellow blue)
  @valid_icons [nil, "rocket", "play", "stop", "trash", "arrow-up", "terminal"]

  @snippet_bash ~S"""
                # Termigate notifications — add to ~/.bashrc
                if [ -n "$TMUX_PANE" ]; then
                  __termigate_precmd() {
                    local exit_code=$?
                    local duration=$(( SECONDS - ${__termigate_cmd_start:-$SECONDS} ))
                    if [ -n "$__termigate_cmd_start" ]; then
                      printf '\033]termigate;cmd_done;%s;%s;%s\007' "$exit_code" "${__termigate_cmd_name:-unknown}" "$duration"
                    fi
                    unset __termigate_cmd_start __termigate_cmd_name
                  }
                  __termigate_preexec() {
                    if [ -z "$__termigate_cmd_start" ]; then
                      __termigate_cmd_start=$SECONDS
                      __termigate_cmd_name="${BASH_COMMAND%% *}"
                    fi
                  }
                  PROMPT_COMMAND+=(__termigate_precmd)
                  __termigate_prev_trap=$(trap -p DEBUG)
                  trap '__termigate_preexec; '"${__termigate_prev_trap:+${__termigate_prev_trap#trap -- }}" DEBUG
                fi
                """
                |> String.trim()

  @snippet_zsh ~S"""
               # Termigate notifications — add to ~/.zshrc
               if [[ -n "$TMUX_PANE" ]]; then
                 __termigate_preexec() {
                   __termigate_cmd_start=$SECONDS
                   __termigate_cmd_name="${1%% *}"
                 }
                 __termigate_precmd() {
                   local exit_code=$?
                   if [[ -n "$__termigate_cmd_start" ]]; then
                     local duration=$(( SECONDS - __termigate_cmd_start ))
                     printf '\033]termigate;cmd_done;%s;%s;%s\007' "$exit_code" "$__termigate_cmd_name" "$duration"
                     unset __termigate_cmd_start __termigate_cmd_name
                   fi
                 }
                 precmd_functions+=(__termigate_precmd)
                 preexec_functions+=(__termigate_preexec)
               fi
               """
               |> String.trim()

  @snippet_fish ~S"""
                # Termigate notifications — add to ~/.config/fish/config.fish
                if set -q TMUX_PANE
                  function __termigate_preexec --on-event fish_preexec
                    set -g __termigate_cmd_name (string split ' ' -- $argv[1])[1]
                  end
                  function __termigate_postexec --on-event fish_postexec
                    set -l exit_code $status
                    set -l duration (math "$CMD_DURATION / 1000")
                    if set -q __termigate_cmd_name
                      printf '\e]termigate;cmd_done;%s;%s;%s\a' $exit_code $__termigate_cmd_name $duration
                      set -e __termigate_cmd_name
                    end
                  end
                end
                """
                |> String.trim()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Termigate.PubSub, "config")
    end

    config = Config.get()
    terminal = config["terminal"] || %{}
    notif = config["notifications"] || %{}

    socket =
      socket
      |> assign(:quick_actions, config["quick_actions"] || [])
      |> assign(:quick_actions_enabled, config["quick_actions_enabled"] != false)
      |> assign(:session_ttl_hours, Auth.session_ttl_hours())
      |> assign(:editing, nil)
      |> assign(:form_data, default_form())
      |> assign(:form_errors, %{})
      |> assign(:terminal, terminal)
      |> assign(:pw_current, "")
      |> assign(:pw_new, "")
      |> assign(:pw_confirm, "")
      |> assign(:page_title, "Settings")
      |> assign(:notification_mode, notif["mode"] || "disabled")
      |> assign(:notification_idle_threshold, notif["idle_threshold"] || 10)
      |> assign(:notification_min_duration, notif["min_duration"] || 5)
      |> assign(:notification_sound, notif["sound"] == true)
      |> assign(:bash_version_display, nil)
      |> assign(:bash_shell_integration_ok, nil)
      |> assign(:snippet_bash, @snippet_bash)
      |> assign(:snippet_zsh, @snippet_zsh)
      |> assign(:snippet_fish, @snippet_fish)
      |> assign(:config_path, Config.config_path())

    {:ok, socket}
  end

  @impl true
  def handle_info({:config_changed, config}, socket) do
    ttl = get_in(config, ["auth", "session_ttl_hours"]) || Auth.default_session_ttl_hours()
    notif = config["notifications"] || %{}

    {:noreply,
     socket
     |> assign(:quick_actions, config["quick_actions"] || [])
     |> assign(:quick_actions_enabled, config["quick_actions_enabled"] != false)
     |> assign(:session_ttl_hours, ttl)
     |> assign(:terminal, config["terminal"] || %{})
     |> assign(:notification_mode, notif["mode"] || "disabled")
     |> assign(:notification_idle_threshold, notif["idle_threshold"] || 10)
     |> assign(:notification_min_duration, notif["min_duration"] || 5)
     |> assign(:notification_sound, notif["sound"] == true)}
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
          Logger.info("Quick action saved: #{action["label"]}")

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
        Logger.info("Quick action deleted: #{id}")
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
            Logger.info("Session TTL updated to #{hours}h")

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

  def handle_event("toggle_quick_actions", _params, socket) do
    enabled = !socket.assigns.quick_actions_enabled

    case Config.update(fn config -> Map.put(config, "quick_actions_enabled", enabled) end) do
      {:ok, _} ->
        {:noreply, assign(socket, :quick_actions_enabled, enabled)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("update_terminal", params, socket) do
    terminal = socket.assigns.terminal

    terminal =
      terminal
      |> maybe_put("font_size", params["font_size"], &parse_int/1)
      |> maybe_put("font_family", params["font_family"], & &1)
      |> maybe_put("theme", params["theme"], & &1)
      |> maybe_put("cursor_style", params["cursor_style"], & &1)
      |> maybe_put_bool("cursor_blink", params)
      |> maybe_put_bool("show_toolbar", params)

    case Config.update(fn config -> Map.put(config, "terminal", terminal) end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:terminal, terminal)
         |> put_flash(:info, "Terminal settings saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("change_password", params, socket) do
    current = params["current_password"] || ""
    new_pw = params["new_password"] || ""
    confirm = params["confirm_password"] || ""

    cond do
      String.length(new_pw) < 8 ->
        {:noreply, put_flash(socket, :error, "New password must be at least 8 characters.")}

      new_pw != confirm ->
        {:noreply, put_flash(socket, :error, "New passwords do not match.")}

      true ->
        case Auth.change_password(current, new_pw) do
          :ok ->
            {:noreply,
             socket
             |> assign(:pw_current, "")
             |> assign(:pw_new, "")
             |> assign(:pw_confirm, "")
             |> put_flash(:info, "Password changed successfully.")}

          {:error, :invalid_current} ->
            {:noreply, put_flash(socket, :error, "Current password is incorrect.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to change password: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("update_notification_setting", %{"key" => key, "value" => value}, socket) do
    value =
      case key do
        "idle_threshold" -> parse_int(value) || 10
        "min_duration" -> parse_int(value) || 5
        "sound" -> value in ["true", true]
        "mode" -> if value in ~w(disabled activity shell), do: value, else: "disabled"
        _ -> value
      end

    case Config.update(fn config ->
           notif = Map.get(config, "notifications", %{})
           Map.put(config, "notifications", Map.put(notif, key, value))
         end) do
      {:ok, _} ->
        # Check bash version when switching to shell mode
        socket =
          if key == "mode" and value == "shell" do
            check_bash_version(socket)
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("test_notification", _params, socket) do
    {:noreply, push_event(socket, "test_notification", %{})}
  end

  def handle_event("check_bash_version", _params, socket) do
    {:noreply, check_bash_version(socket)}
  end

  def handle_event("reset_config", _params, socket) do
    case Config.reset() do
      {:ok, _config} ->
        Logger.info("Config reset to defaults")

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

  defp maybe_put(map, _key, nil, _transform), do: map
  defp maybe_put(map, key, value, transform), do: Map.put(map, key, transform.(value))

  defp maybe_put_bool(map, key, params) do
    Map.put(map, key, params[key] in [true, "true", "on"])
  end

  defp check_bash_version(socket) do
    version =
      case System.cmd("bash", ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/version (\d+)\.(\d+)/, output) do
            [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
            _ -> :unknown
          end

        _ ->
          :unknown
      end

    {bash_ok, display} =
      case version do
        {major, minor} when major > 5 -> {true, "#{major}.#{minor}"}
        {5, minor} when minor >= 1 -> {true, "5.#{minor}"}
        {major, minor} -> {false, "#{major}.#{minor}"}
        :unknown -> {nil, nil}
      end

    socket
    |> assign(:bash_shell_integration_ok, bash_ok)
    |> assign(:bash_version_display, display)
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil
end
