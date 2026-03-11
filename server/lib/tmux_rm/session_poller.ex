defmodule TmuxRm.SessionPoller do
  @moduledoc """
  Polls tmux for session/pane state on an interval and broadcasts changes.

  Subscribes to `"sessions:mutations"` for immediate re-polls on app-driven changes.
  Broadcasts `{:sessions_updated, sessions}` on `"sessions:state"` when state changes.
  Broadcasts `{:tmux_status_changed, status}` on `"sessions:state"` when tmux availability changes.
  """
  use GenServer

  require Logger

  @pubsub TmuxRm.PubSub
  @state_topic "sessions:state"
  @mutations_topic "sessions:mutations"

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Returns the last-known session list. Returns `[]` before the first poll."
  @spec get() :: [map()]
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Returns the current tmux status: :ok, :no_server, :not_found, or {:error, message}."
  @spec tmux_status() :: :ok | :no_server | :not_found | {:error, String.t()}
  def tmux_status do
    GenServer.call(__MODULE__, :tmux_status)
  end

  @doc "Force an immediate re-poll."
  @spec force_poll() :: :ok
  def force_poll do
    GenServer.cast(__MODULE__, :force_poll)
  end

  # --- Callbacks ---

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(@pubsub, @mutations_topic)

    state = %{
      sessions: [],
      tmux_status: :ok,
      poll_timer: nil
    }

    {:ok, state, {:continue, :initial_poll}}
  end

  @impl true
  def handle_continue(:initial_poll, state) do
    state = do_poll(state)
    state = schedule_poll(state)
    Logger.info("SessionPoller started, found #{length(state.sessions)} sessions")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.sessions, state}
  end

  def handle_call(:tmux_status, _from, state) do
    {:reply, state.tmux_status, state}
  end

  @impl true
  def handle_cast(:force_poll, state) do
    state = do_poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    state = schedule_poll(state)
    {:noreply, state}
  end

  def handle_info({:sessions_changed}, state) do
    # Immediate re-poll on mutation
    state = do_poll(state)
    {:noreply, state}
  end

  # --- Private ---

  defp do_poll(state) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case TmuxRm.TmuxManager.list_sessions() do
        {:ok, sessions} ->
          sessions_with_panes = fetch_panes(sessions)
          new_tmux_status = :ok

          state = maybe_broadcast_tmux_status(state, new_tmux_status)
          state = maybe_broadcast_sessions(state, sessions_with_panes)

          %{state | sessions: sessions_with_panes, tmux_status: new_tmux_status}

        {:error, :tmux_not_found} ->
          state = maybe_broadcast_tmux_status(state, :not_found)
          %{state | tmux_status: :not_found}

        {:error, reason} ->
          new_status = {:error, to_string(reason)}
          state = maybe_broadcast_tmux_status(state, new_status)
          %{state | tmux_status: new_status}
      end

    duration = System.monotonic_time(:millisecond) - start_time
    session_count = length(result.sessions)

    :telemetry.execute(
      [:tmux_rm, :session_poller, :poll],
      %{duration_ms: duration, session_count: session_count},
      %{}
    )

    result
  end

  defp fetch_panes(sessions) do
    Enum.map(sessions, fn session ->
      panes =
        case TmuxRm.TmuxManager.list_panes(session.name) do
          {:ok, panes_by_window} -> panes_by_window
          {:error, _} -> %{}
        end

      Map.put(session, :panes, panes)
    end)
  end

  defp maybe_broadcast_sessions(state, new_sessions) do
    if sessions_changed?(state.sessions, new_sessions) do
      Phoenix.PubSub.broadcast(@pubsub, @state_topic, {:sessions_updated, new_sessions})
    end

    state
  end

  defp maybe_broadcast_tmux_status(state, new_status) do
    if state.tmux_status != new_status do
      Logger.info("tmux status changed: #{inspect(state.tmux_status)} -> #{inspect(new_status)}")
      Phoenix.PubSub.broadcast(@pubsub, @state_topic, {:tmux_status_changed, new_status})
    end

    state
  end

  defp sessions_changed?(old, new) do
    normalize(old) != normalize(new)
  end

  defp normalize(sessions) do
    sessions
    |> Enum.map(fn s ->
      %{
        name: s.name,
        windows: s.windows,
        attached?: s.attached?,
        panes: Map.get(s, :panes, %{})
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp schedule_poll(state) do
    interval = Application.get_env(:tmux_rm, :session_poll_interval, 3_000)
    timer = Process.send_after(self(), :poll, interval)
    %{state | poll_timer: timer}
  end
end
