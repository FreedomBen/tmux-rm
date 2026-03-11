defmodule TmuxRmWeb.RateLimitStore do
  @moduledoc """
  ETS-backed rate limiting store.

  Keys: {ip, endpoint_key, window_minute} → count.
  Periodic cleanup sweeps entries older than 2 minutes.
  """
  use GenServer

  require Logger

  @table :rate_limit_store
  @cleanup_interval :timer.minutes(5)
  @max_entries 100_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Check and increment rate limit counter.
  Returns :ok or {:error, :rate_limited, retry_after_seconds}.
  """
  @spec check(String.t(), atom(), {pos_integer(), pos_integer()}) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check(ip, key, {max_requests, window_seconds}) do
    window = System.system_time(:second) |> div(window_seconds)
    ets_key = {ip, key, window}

    count =
      case :ets.update_counter(@table, ets_key, {2, 1}, {ets_key, 0}) do
        n when is_integer(n) -> n
      end

    if count > max_requests do
      :telemetry.execute(
        [:tmux_rm, :auth, :rate_limited],
        %{},
        %{ip: ip, endpoint_key: key}
      )

      retry_after = window_seconds - rem(System.system_time(:second), window_seconds)
      {:error, :rate_limited, retry_after}
    else
      :ok
    end
  end

  # --- GenServer ---

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      Logger.warning("Rate limit table exceeded #{@max_entries} entries (#{size}), flushing")
      :ets.delete_all_objects(@table)
    else
      # Sweep entries older than 2 minutes
      cutoff_60 = System.system_time(:second) |> div(60) |> Kernel.-(2)
      # We can't easily filter by window since keys use varying window sizes,
      # but we can delete all entries — they'll be recreated on next request.
      # For simplicity, just clear entries older than 2 minutes for 60s windows.
      :ets.foldl(
        fn {{_ip, _key, window} = ets_key, _count}, acc ->
          if window < cutoff_60, do: :ets.delete(@table, ets_key)
          acc
        end,
        nil,
        @table
      )
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
