defmodule Termigate.LayoutPoller do
  @moduledoc """
  GenServer that polls tmux for pane layout of a specific window.
  Broadcasts layout changes via PubSub. One poller per active window,
  started lazily and shut down after a grace period with no subscribers.
  """
  use GenServer

  require Logger

  @poll_interval 2_000
  @grace_period 30_000

  defstruct [
    :session,
    :window,
    :layout,
    :timer_ref,
    :grace_timer_ref,
    :subscriber_count,
    window_gone?: false
  ]

  # --- Public API ---

  @doc """
  Get the current layout for a session window. Starts a poller if needed.
  Returns `{:ok, panes}` or `{:error, reason}`.
  """
  def get(session, window) do
    case ensure_started(session, window) do
      {:ok, pid} -> GenServer.call(pid, :get_layout)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Subscribe to layout updates for a session window."
  def subscribe(session, window) do
    topic = topic(session, window)
    Phoenix.PubSub.subscribe(Termigate.PubSub, topic)

    case ensure_started(session, window) do
      {:ok, pid} ->
        GenServer.cast(pid, :viewer_joined)
        {:ok, pid}

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Termigate.PubSub, topic)
        {:error, reason}
    end
  end

  @doc "Unsubscribe from layout updates."
  def unsubscribe(session, window) do
    Phoenix.PubSub.unsubscribe(Termigate.PubSub, topic(session, window))

    case lookup(session, window) do
      {:ok, pid} -> GenServer.cast(pid, :viewer_left)
      _ -> :ok
    end
  end

  def topic(session, window), do: "layout:#{session}:#{window}"

  # --- GenServer callbacks ---

  def start_link({session, window}) do
    name = {:via, Registry, {Termigate.PaneRegistry, {:layout_poller, session, window}}}
    GenServer.start_link(__MODULE__, {session, window}, name: name)
  end

  @impl true
  def init({session, window}) do
    Phoenix.PubSub.subscribe(Termigate.PubSub, "sessions:mutations")

    state = %__MODULE__{
      session: session,
      window: window,
      layout: nil,
      timer_ref: nil,
      grace_timer_ref: nil,
      subscriber_count: 0,
      window_gone?: false
    }

    {:ok, state, {:continue, :initial_poll}}
  end

  @impl true
  def handle_continue(:initial_poll, state) do
    state = do_poll(state)
    timer_ref = schedule_poll()
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:get_layout, _from, state) do
    {:reply, {:ok, state.layout || []}, state}
  end

  @impl true
  def handle_cast(:viewer_joined, state) do
    state = %{state | subscriber_count: state.subscriber_count + 1}

    state =
      if state.grace_timer_ref do
        Process.cancel_timer(state.grace_timer_ref)
        %{state | grace_timer_ref: nil}
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast(:viewer_left, state) do
    count = max(state.subscriber_count - 1, 0)
    state = %{state | subscriber_count: count}

    state =
      if count == 0 do
        ref = Process.send_after(self(), :grace_period_expired, @grace_period)
        %{state | grace_timer_ref: ref}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    timer_ref = schedule_poll()
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info({:sessions_changed}, state) do
    # Immediate re-poll on app-driven mutations
    state = do_poll(state)
    {:noreply, state}
  end

  def handle_info(:grace_period_expired, state) do
    if state.subscriber_count == 0 do
      Logger.info(
        "LayoutPoller shutting down for #{state.session}:#{state.window} (grace period)"
      )

      {:stop, :normal, state}
    else
      {:noreply, %{state | grace_timer_ref: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp do_poll(state) do
    case fetch_layout(state.session, state.window) do
      {:ok, panes} ->
        if state.window_gone? do
          Logger.info("LayoutPoller: window #{state.session}:#{state.window} is back")
        end

        if panes != state.layout do
          Phoenix.PubSub.broadcast(
            Termigate.PubSub,
            topic(state.session, state.window),
            {:layout_updated, panes}
          )
        end

        %{state | layout: panes, window_gone?: false}

      {:error, :window_not_found} ->
        if state.window_gone? do
          # Already reported — stay silent to avoid log/broadcast spam
          state
        else
          Phoenix.PubSub.broadcast(
            Termigate.PubSub,
            topic(state.session, state.window),
            {:layout_updated, []}
          )

          Logger.info("LayoutPoller: window #{state.session}:#{state.window} no longer exists")
          # Remain polling in case the window is recreated; grace-period shutdown still applies
          %{state | layout: [], window_gone?: true}
        end

      {:error, _reason} ->
        state
    end
  rescue
    e ->
      Logger.warning(
        "LayoutPoller poll error for #{state.session}:#{state.window}: #{inspect(e)}"
      )

      state
  end

  defp fetch_layout(session, window) do
    format =
      "\#{pane_id}\t\#{pane_left}\t\#{pane_top}\t\#{pane_width}\t\#{pane_height}\t\#{pane_index}\t\#{pane_current_command}"

    target = "#{session}:#{window}"

    case command_runner().run(["list-panes", "-t", target, "-F", format]) do
      {:ok, output} ->
        panes =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_layout_line(session, window, &1))
          |> Enum.reject(&is_nil/1)

        {:ok, panes}

      {:error, {msg, _code}} ->
        if String.contains?(msg, "can't find") or String.contains?(msg, "not found") do
          {:error, :window_not_found}
        else
          {:error, :tmux_error}
        end
    end
  end

  defp parse_layout_line(session, window, line) do
    case String.split(line, "\t") do
      [pane_id, left, top, width, height, index, command] ->
        %{
          pane_id: pane_id,
          target: "#{session}:#{window}.#{index}",
          left: String.to_integer(left),
          top: String.to_integer(top),
          width: String.to_integer(width),
          height: String.to_integer(height),
          index: String.to_integer(index),
          command: command
        }

      _ ->
        nil
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp ensure_started(session, window) do
    case lookup(session, window) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        case DynamicSupervisor.start_child(
               Termigate.LayoutPollerSupervisor,
               {__MODULE__, {session, window}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lookup(session, window) do
    case Registry.lookup(Termigate.PaneRegistry, {:layout_poller, session, window}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp command_runner, do: Application.get_env(:termigate, :command_runner)
end
