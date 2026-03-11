defmodule TmuxRm.Config do
  @moduledoc "Config GenServer — manages YAML config file with quick actions."
  use GenServer

  require Logger

  @config_topic "config"
  @default_config %{"quick_actions" => []}
  @header_comment """
  # tmux-rm configuration
  # Edit this file directly or use the web UI at /settings
  # Changes are detected automatically within a few seconds.
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
  """

  # --- Public API ---

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
    poll_interval = Application.get_env(:tmux_rm, :config_poll_interval, 2_000)

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
    new_config = fun.(state.config)

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
      {:ok, config, mtime} ->
        config = ensure_action_ids(config)

        Logger.info(
          "Config loaded from #{state.path} (#{length(config["quick_actions"] || [])} quick actions)"
        )

        %{state | config: config, mtime: mtime}

      {:error, :enoent} ->
        Logger.info("Config file not found, creating defaults at #{state.path}")

        case write_config(state.path, @default_config) do
          {:ok, mtime} -> %{state | config: @default_config, mtime: mtime}
          {:error, _} -> %{state | config: @default_config}
        end

      {:error, reason} ->
        Logger.warning("Failed to read config: #{inspect(reason)}, using defaults")
        %{state | config: @default_config}
    end
  end

  defp check_mtime(state) do
    case File.stat(state.path) do
      {:ok, %{mtime: mtime}} when mtime != state.mtime ->
        case read_config(state.path) do
          {:ok, config, ^mtime} ->
            config = ensure_action_ids(config)
            Logger.info("Config file changed, reloading")
            broadcast_change(config)
            %{state | config: config, mtime: mtime}

          {:ok, config, new_mtime} ->
            config = ensure_action_ids(config)
            Logger.info("Config file changed, reloading")
            broadcast_change(config)
            %{state | config: config, mtime: new_mtime}

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
          []
      end

    %{"quick_actions" => actions}
  end

  defp normalize_config(_), do: @default_config

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

  defp ensure_action_ids(config) do
    actions = config["quick_actions"] || []
    needs_ids? = Enum.any?(actions, fn a -> is_nil(a["id"]) or a["id"] == "" end)

    if needs_ids? do
      updated = Enum.map(actions, &ensure_id/1)
      config = Map.put(config, "quick_actions", updated)
      # Rewrite file with generated IDs
      spawn(fn ->
        path = config_path()
        write_config(path, config)
      end)

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
    System.get_env("RCA_CONFIG_PATH") ||
      Path.join([System.user_home!(), ".config", "tmux_rm", "config.yaml"])
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp broadcast_change(config) do
    try do
      Phoenix.PubSub.broadcast(TmuxRm.PubSub, @config_topic, {:config_changed, config})
    rescue
      ArgumentError -> :ok
    end
  end
end
