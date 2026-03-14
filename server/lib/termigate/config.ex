defmodule Termigate.Config do
  @moduledoc "Config GenServer — manages YAML config file with quick actions."
  use GenServer

  require Logger

  @config_topic "config"
  @default_config %{
    "quick_actions" => [
      %{
        "label" => "Clear",
        "command" => "clear",
        "color" => "default",
        "icon" => "terminal",
        "confirm" => false
      },
      %{
        "label" => "Disk Usage",
        "command" => "df -h",
        "color" => "blue",
        "icon" => "terminal",
        "confirm" => false
      },
      %{
        "label" => "System Info",
        "command" => "uname -a",
        "color" => "blue",
        "icon" => "terminal",
        "confirm" => false
      },
      %{
        "label" => "Top",
        "command" => "top",
        "color" => "green",
        "icon" => "play",
        "confirm" => false
      },
      %{
        "label" => "Git Status",
        "command" => "git status",
        "color" => "default",
        "icon" => "terminal",
        "confirm" => false
      }
    ],
    "quick_actions_enabled" => true,
    "terminal" => %{
      "font_size" => 14,
      "font_family" => "monospace",
      "theme" => "dark",
      "custom_theme" => %{},
      "cursor_style" => "block",
      "cursor_blink" => true,
      "show_toolbar" => true
    },
    "notifications" => %{
      "mode" => "disabled",
      "idle_threshold" => 10,
      "min_duration" => 5,
      "sound" => false
    }
  }
  @header_comment """
  # termigate configuration
  # Edit this file directly or use the web UI at /settings
  # Changes are detected automatically within a few seconds.
  #
  # --- auth ---
  # Authentication settings. Managed via /setup or /settings.
  # Do not edit password_hash manually — use the UI or `mix termigate.change_password`.
  #
  #   username:           Your login username
  #   password_hash:      Hashed password (auto-generated)
  #   session_ttl_hours:  How long sessions stay valid before requiring
  #                       re-authentication (default: 168 = 1 week)
  #
  # --- quick_actions ---
  # Quick actions appear as buttons above the terminal view.
  # Each action sends its command to the active pane.
  #
  # Fields:
  #   label:    (required) Button text displayed in the UI
  #   command:  (required) Shell command to send to the pane (max 4096 bytes)
  #             A newline is appended automatically when executed.
  #   confirm:  (optional, default: false) If true, show a confirmation dialog
  #             before running. Recommended for destructive commands.
  #   color:    (optional, default: "default") Button color.
  #             Options: default, green, red, yellow, blue
  #   icon:     (optional) Icon shown before the label.
  #             Options: rocket, play, stop, trash, arrow-up, terminal
  #
  # Example:
  #
  # quick_actions:
  #   - label: "Deploy"
  #     command: "bash deploy.sh"
  #     confirm: true
  #     color: green
  #     icon: rocket
  #   - label: "Restart"
  #     command: "sudo systemctl restart myapp"
  #     confirm: true
  #     color: yellow
  #     icon: play
  #   - label: "Logs"
  #     command: "tail -f /var/log/myapp.log"
  #     color: blue
  #     icon: terminal
  #
  # --- terminal ---
  # Terminal display preferences. Synced to all connected browsers.
  #
  # Fields:
  #   font_size:     Font size in pixels (8–32, default: 14)
  #   font_family:   CSS font-family string (default: "monospace")
  #   theme:         Color theme: dark, light, solarizedDark, solarizedLight, custom
  #   custom_theme:  Custom color overrides (when theme is "custom")
  #                  Keys: foreground, background, cursor, selectionBackground
  #   cursor_style:  block, underline, or bar (default: "block")
  #   cursor_blink:  true/false (default: true)
  #   show_toolbar:  Show virtual toolbar on mobile (default: true)
  """

  # --- Public API ---

  @doc "Returns the default config map."
  def defaults, do: @default_config

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current config."
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Update config via a transform function. Serialized through the GenServer."
  def update(fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, fun})
  end

  @doc "Upsert a quick action. If id is nil, generates one."
  def upsert_action(action) do
    update(fn config ->
      actions = config["quick_actions"] || []
      action = action |> normalize_action() |> ensure_id()
      id = action["id"]

      updated =
        case Enum.find_index(actions, &(&1["id"] == id)) do
          nil -> actions ++ [action]
          idx -> List.replace_at(actions, idx, action)
        end

      Map.put(config, "quick_actions", updated)
    end)
  end

  @doc "Delete a quick action by ID."
  def delete_action(id) do
    update(fn config ->
      actions = config["quick_actions"] || []
      Map.put(config, "quick_actions", Enum.reject(actions, &(&1["id"] == id)))
    end)
  end

  @doc "Reset config to defaults (preserves auth section)."
  def reset do
    update(fn config ->
      defaults = ensure_action_ids(@default_config)

      case config["auth"] do
        auth when is_map(auth) and map_size(auth) > 0 ->
          Map.put(defaults, "auth", auth)

        _ ->
          defaults
      end
    end)
  end

  @doc "Reorder quick actions by list of IDs."
  def reorder_actions(ids) when is_list(ids) do
    update(fn config ->
      actions = config["quick_actions"] || []
      by_id = Map.new(actions, &{&1["id"], &1})

      reordered =
        ids
        |> Enum.map(&Map.get(by_id, &1))
        |> Enum.reject(&is_nil/1)

      # Append any actions not in the ID list
      remaining = Enum.reject(actions, &(&1["id"] in ids))

      Map.put(config, "quick_actions", reordered ++ remaining)
    end)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    path = config_path()
    poll_interval = Application.get_env(:termigate, :config_poll_interval, 2_000)

    state = %{
      path: path,
      config: @default_config,
      mtime: nil,
      poll_interval: poll_interval
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    state = load_config(state)
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:update, fun}, _from, state) do
    new_config = fun.(state.config) |> normalize_config()

    case write_config(state.path, new_config) do
      {:ok, mtime} ->
        broadcast_change(new_config)
        Logger.debug("Config updated")
        {:reply, {:ok, new_config}, %{state | config: new_config, mtime: mtime}}

      {:error, reason} ->
        Logger.warning("Failed to write config: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = check_mtime(state)
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  # --- Private ---

  defp load_config(state) do
    case read_config(state.path) do
      {:ok, config, _mtime} ->
        config = ensure_action_ids(config, true)

        # Re-stat the file in case ensure_action_ids wrote back
        mtime =
          case File.stat(state.path) do
            {:ok, %{mtime: m}} -> m
            _ -> nil
          end

        Logger.info(
          "Config loaded from #{state.path} (#{length(config["quick_actions"] || [])} quick actions)"
        )

        %{state | config: config, mtime: mtime}

      {:error, :enoent} ->
        Logger.info("Config file not found, creating defaults at #{state.path}")
        defaults = ensure_action_ids(@default_config)

        case write_config(state.path, defaults) do
          {:ok, mtime} -> %{state | config: defaults, mtime: mtime}
          {:error, _} -> %{state | config: defaults}
        end

      {:error, reason} ->
        Logger.warning("Failed to read config: #{inspect(reason)}, using defaults")
        %{state | config: ensure_action_ids(@default_config)}
    end
  end

  defp check_mtime(state) do
    case File.stat(state.path) do
      {:ok, %{mtime: mtime}} when mtime != state.mtime ->
        case read_config(state.path) do
          {:ok, config, _mtime} ->
            config = ensure_action_ids(config, true)

            # Re-stat in case ensure_action_ids wrote back
            final_mtime =
              case File.stat(state.path) do
                {:ok, %{mtime: m}} -> m
                _ -> nil
              end

            Logger.info("Config file changed, reloading")
            broadcast_change(config)
            %{state | config: config, mtime: final_mtime}

          {:error, reason} ->
            Logger.warning("Malformed config file, keeping last good config: #{inspect(reason)}")
            state
        end

      {:ok, _} ->
        # mtime unchanged
        state

      {:error, :enoent} ->
        Logger.warning("Config file deleted, keeping last good config")
        state

      {:error, _} ->
        state
    end
  end

  defp read_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      mtime =
        case File.stat(path) do
          {:ok, %{mtime: m}} -> m
          _ -> nil
        end

      config = normalize_config(parsed)
      {:ok, config, mtime}
    end
  end

  defp write_config(path, config) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    yaml = to_yaml(config)
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, yaml),
         :ok <- File.rename(tmp_path, path) do
      # Set permissions
      File.chmod(path, 0o600)

      mtime =
        case File.stat(path) do
          {:ok, %{mtime: m}} -> m
          _ -> nil
        end

      {:ok, mtime}
    else
      error ->
        File.rm(tmp_path)
        error
    end
  end

  defp to_yaml(config) do
    # Build clean map for serialization — omit nil fields from actions
    clean_actions =
      (config["quick_actions"] || [])
      |> Enum.map(fn action ->
        action
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)

    clean_config = %{"quick_actions" => clean_actions}

    # Include terminal section
    clean_config =
      Map.put(clean_config, "terminal", config["terminal"] || @default_config["terminal"])

    # Include notifications section
    clean_config =
      Map.put(
        clean_config,
        "notifications",
        config["notifications"] || @default_config["notifications"]
      )

    # Include auth section if present
    clean_config =
      case config["auth"] do
        auth when is_map(auth) and map_size(auth) > 0 ->
          Map.put(clean_config, "auth", auth)

        _ ->
          clean_config
      end

    yaml_body =
      case Ymlr.document(clean_config) do
        {:ok, doc} -> doc
        doc when is_binary(doc) -> doc
      end

    @header_comment <> "\n" <> yaml_body
  end

  defp normalize_config(parsed) when is_map(parsed) do
    actions =
      case parsed["quick_actions"] do
        list when is_list(list) ->
          Enum.map(list, &normalize_action/1)

        _ ->
          # Use default quick actions when the key is missing (e.g., fresh config with only auth)
          @default_config["quick_actions"]
      end

    config =
      %{"quick_actions" => actions}
      |> Map.put("terminal", parsed["terminal"])
      |> Map.put("notifications", parsed["notifications"])
      |> normalize_terminal_section()
      |> normalize_notifications_section()

    case parsed["auth"] do
      auth when is_map(auth) and map_size(auth) > 0 ->
        Map.put(config, "auth", normalize_auth_section(auth))

      _ ->
        config
    end
  end

  defp normalize_config(_), do: @default_config

  @valid_themes ~w(dark light solarizedDark solarizedLight custom)
  @valid_cursor_styles ~w(block underline bar)

  defp normalize_terminal_section(config) do
    defaults = @default_config["terminal"]
    terminal = Map.merge(defaults, config["terminal"] || %{})

    terminal = %{
      "font_size" => clamp(terminal["font_size"], 8, 32),
      "font_family" =>
        if(is_binary(terminal["font_family"]) and terminal["font_family"] != "",
          do: terminal["font_family"],
          else: "monospace"
        ),
      "theme" => if(terminal["theme"] in @valid_themes, do: terminal["theme"], else: "dark"),
      "custom_theme" =>
        if(is_map(terminal["custom_theme"]), do: terminal["custom_theme"], else: %{}),
      "cursor_style" =>
        if(terminal["cursor_style"] in @valid_cursor_styles,
          do: terminal["cursor_style"],
          else: "block"
        ),
      "cursor_blink" => terminal["cursor_blink"] == true,
      "show_toolbar" => terminal["show_toolbar"] != false
    }

    Map.put(config, "terminal", terminal)
  end

  defp normalize_notifications_section(config) do
    defaults = @default_config["notifications"]
    notif = Map.merge(defaults, config["notifications"] || %{})

    notif = %{
      "mode" =>
        if(notif["mode"] in ~w(disabled activity shell), do: notif["mode"], else: "disabled"),
      "idle_threshold" => notif["idle_threshold"] |> clamp(3, 120),
      "min_duration" => notif["min_duration"] |> clamp(0, 600),
      "sound" => notif["sound"] == true
    }

    Map.put(config, "notifications", notif)
  end

  defp clamp(value, min_val, max_val) when is_number(value),
    do: max(min_val, min(max_val, value))

  defp clamp(_value, min_val, _max_val), do: min_val

  defp normalize_auth_section(auth) do
    result = %{}

    result =
      if is_binary(auth["username"]) and auth["username"] != "",
        do: Map.put(result, "username", auth["username"]),
        else: result

    result =
      if is_binary(auth["password_hash"]) and auth["password_hash"] != "",
        do: Map.put(result, "password_hash", auth["password_hash"]),
        else: result

    result =
      if is_number(auth["session_ttl_hours"]) and auth["session_ttl_hours"] > 0,
        do: Map.put(result, "session_ttl_hours", auth["session_ttl_hours"]),
        else: result

    result
  end

  defp normalize_action(action) when is_map(action) do
    %{
      "id" => action["id"],
      "label" => to_string(action["label"] || ""),
      "command" => to_string(action["command"] || ""),
      "confirm" => action["confirm"] == true,
      "color" => validate_color(action["color"]),
      "icon" => validate_icon(action["icon"])
    }
  end

  defp normalize_action(_), do: nil

  @valid_colors ~w(default green red yellow blue)
  defp validate_color(color) when color in @valid_colors, do: color
  defp validate_color(_), do: "default"

  @valid_icons ~w(rocket play stop trash arrow-up terminal)
  defp validate_icon(icon) when icon in @valid_icons, do: icon
  defp validate_icon(_), do: nil

  defp ensure_action_ids(config, write_back \\ false) do
    actions = config["quick_actions"] || []
    needs_ids? = Enum.any?(actions, fn a -> is_nil(a["id"]) or a["id"] == "" end)

    if needs_ids? do
      updated = Enum.map(actions, &ensure_id/1)
      config = Map.put(config, "quick_actions", updated)

      # Write synchronously to avoid race conditions — a spawned process
      # could overwrite auth added by a concurrent Config.update call.
      if write_back do
        write_config(config_path(), config)
      end

      config
    else
      config
    end
  end

  defp ensure_id(%{"id" => id} = action) when is_binary(id) and id != "", do: action

  defp ensure_id(action) do
    Map.put(action, "id", generate_id())
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp config_path do
    System.get_env("TERMIGATE_CONFIG_PATH") ||
      Path.join([System.user_home!(), ".config", "termigate", "config.yaml"])
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp broadcast_change(config) do
    try do
      Phoenix.PubSub.broadcast(Termigate.PubSub, @config_topic, {:config_changed, config})
    rescue
      ArgumentError -> :ok
    end
  end
end
