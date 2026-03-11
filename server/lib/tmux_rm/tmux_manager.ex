defmodule TmuxRm.TmuxManager do
  @moduledoc """
  Stateless module for managing tmux sessions and panes.
  All commands go through the configured CommandRunner.
  """

  alias TmuxRm.Tmux.{Session, Pane}

  require Logger

  @session_name_regex ~r/^[a-zA-Z0-9_-]+$/

  # --- Public API ---

  @doc "List all tmux sessions."
  @spec list_sessions() :: {:ok, [Session.t()]} | {:error, atom()}
  def list_sessions do
    format = "\#{session_name}\t\#{session_windows}\t\#{session_created}\t\#{session_attached}"

    case command_runner().run(["list-sessions", "-F", format]) do
      {:ok, output} ->
        sessions =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_session_line/1)

        {:ok, sessions}

      {:error, {msg, _code}} ->
        cond do
          String.contains?(msg, "no server running") or
              String.contains?(msg, "no current client") ->
            {:ok, []}

          String.contains?(msg, "executable file not found") or
              String.contains?(msg, "not found") ->
            {:error, :tmux_not_found}

          true ->
            {:error, :tmux_error}
        end
    end
  end

  @doc "List all panes in a session, grouped by window index."
  @spec list_panes(String.t()) :: {:ok, %{non_neg_integer() => [Pane.t()]}} | {:error, atom()}
  def list_panes(session_name) do
    format =
      "\#{session_name}\t\#{window_index}\t\#{pane_index}\t\#{pane_width}\t\#{pane_height}\t\#{pane_current_command}\t\#{pane_id}"

    case command_runner().run(["list-panes", "-s", "-t", session_name, "-F", format]) do
      {:ok, output} ->
        panes =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_pane_line/1)
          |> Enum.group_by(& &1.window_index)

        {:ok, panes}

      {:error, {msg, _code}} ->
        cond do
          String.contains?(msg, "can't find session") or
              String.contains?(msg, "session not found") ->
            {:error, :session_not_found}

          true ->
            {:error, :tmux_error}
        end
    end
  end

  @doc "Create a new tmux session."
  @spec create_session(String.t(), keyword()) :: {:ok, map()} | {:error, atom() | String.t()}
  def create_session(name, opts \\ []) do
    unless valid_session_name?(name) do
      {:error, :invalid_name}
    else
      cols = Keyword.get(opts, :cols, Application.get_env(:tmux_rm, :default_cols))
      rows = Keyword.get(opts, :rows, Application.get_env(:tmux_rm, :default_rows))
      command = Keyword.get(opts, :command)

      args = ["new-session", "-d", "-s", name, "-x", to_string(cols), "-y", to_string(rows)]
      args = if command, do: args ++ [command], else: args

      case command_runner().run(args) do
        {:ok, _} ->
          broadcast_sessions_changed()
          {:ok, %{name: name}}

        {:error, {msg, _code}} ->
          {:error, msg}
      end
    end
  end

  @doc "Kill a tmux session."
  @spec kill_session(String.t()) :: :ok | {:error, atom() | String.t()}
  def kill_session(name) do
    case command_runner().run(["kill-session", "-t", name]) do
      {:ok, _} ->
        broadcast_sessions_changed()
        :ok

      {:error, {msg, _code}} ->
        {:error, msg}
    end
  end

  @doc "Check if a session exists."
  @spec session_exists?(String.t()) :: boolean()
  def session_exists?(name) do
    case command_runner().run(["has-session", "-t", name]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc "Rename a tmux session."
  @spec rename_session(String.t(), String.t()) :: :ok | {:error, atom() | String.t()}
  def rename_session(old_name, new_name) do
    unless valid_session_name?(new_name) do
      {:error, :invalid_name}
    else
      case command_runner().run(["rename-session", "-t", old_name, new_name]) do
        {:ok, _} ->
          broadcast_sessions_changed()
          :ok

        {:error, {msg, _code}} ->
          {:error, msg}
      end
    end
  end

  @doc "Create a new window in a session."
  @spec create_window(String.t()) :: :ok | {:error, atom() | String.t()}
  def create_window(session_name) do
    case command_runner().run(["new-window", "-t", session_name]) do
      {:ok, _} ->
        broadcast_sessions_changed()
        :ok

      {:error, {msg, _code}} ->
        {:error, msg}
    end
  end

  @doc "Split a pane. Direction is :horizontal or :vertical."
  @spec split_pane(String.t(), :horizontal | :vertical) ::
          {:ok, String.t()} | {:error, String.t()}
  def split_pane(target, direction \\ :horizontal) do
    flag = if direction == :vertical, do: "-v", else: "-h"

    case command_runner().run(["split-window", flag, "-t", target]) do
      {:ok, output} ->
        broadcast_sessions_changed()
        {:ok, output}

      {:error, {msg, _code}} ->
        {:error, msg}
    end
  end

  @doc "Kill a pane."
  @spec kill_pane(String.t()) :: :ok | {:error, String.t()}
  def kill_pane(target) do
    case command_runner().run(["kill-pane", "-t", target]) do
      {:ok, _} ->
        broadcast_sessions_changed()
        :ok

      {:error, {msg, _code}} ->
        {:error, msg}
    end
  end

  @doc "Validate a session name."
  @spec valid_session_name?(String.t()) :: boolean()
  def valid_session_name?(name) when is_binary(name) do
    String.match?(name, @session_name_regex)
  end

  def valid_session_name?(_), do: false

  # --- Private ---

  defp parse_session_line(line) do
    case String.split(line, "\t") do
      [name, windows, created, attached] ->
        %Session{
          name: name,
          windows: parse_int(windows, 0),
          created: parse_unix_timestamp(created),
          attached?: attached != "0"
        }

      _ ->
        %Session{name: line, windows: 0, created: nil, attached?: false}
    end
  end

  defp parse_pane_line(line) do
    case String.split(line, "\t") do
      [session, window_idx, pane_idx, width, height, cmd, pane_id] ->
        %Pane{
          session_name: session,
          window_index: parse_int(window_idx, 0),
          index: parse_int(pane_idx, 0),
          width: parse_int(width, 80),
          height: parse_int(height, 24),
          command: cmd,
          pane_id: pane_id
        }

      _ ->
        %Pane{
          session_name: "",
          window_index: 0,
          index: 0,
          width: 80,
          height: 24,
          command: "",
          pane_id: ""
        }
    end
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_unix_timestamp(str) do
    case Integer.parse(str) do
      {unix, _} -> DateTime.from_unix!(unix)
      :error -> nil
    end
  end

  defp broadcast_sessions_changed do
    Phoenix.PubSub.broadcast(TmuxRm.PubSub, "sessions:mutations", {:sessions_changed})
  end

  defp command_runner, do: Application.get_env(:tmux_rm, :command_runner)
end
