defmodule CtfServer.RateLimiter do
  @moduledoc """
  A small in-memory fixed-window rate limiter, backed by a single ETS table.

  It guards the unauthenticated auth endpoints (login, registration, password
  reset) against brute-force and Argon2 CPU-exhaustion (CWE-307). A caller
  records one "hit" per attempt against a bucket (the endpoint) and an id
  (usually the client IP). When the hit count for the current time window
  exceeds the limit, the limiter denies and reports how long to wait.

  The table is `:public`, so hits go straight to ETS without a GenServer round
  trip; this process only owns the table and sweeps expired windows.

  Limits live under `:rate_limits` in config and are read by `check/2`:

      config :ctf_server, :rate_limits,
        login: {10, 60_000}

  is at most 10 hits per 60 seconds per id.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval 60_000

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a hit against `bucket`/`id` using the limit and window configured
  under `:rate_limits` for `bucket`. See `hit/5`.
  """
  @spec check(atom(), String.t()) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def check(bucket, id) do
    case Keyword.get(rate_limits(), bucket) do
      # An unconfigured bucket is not limited, so a missing config can never
      # lock people out of an auth endpoint (fail open on availability).
      nil -> {:allow, 0}
      {limit, window_ms} -> hit(bucket, id, limit, window_ms)
    end
  end

  @doc """
  Records a hit and returns `{:allow, count}` while at or under `limit`, or
  `{:deny, retry_after_ms}` once the window's count exceeds it. `now` is the
  current time in milliseconds and only needs to be passed in tests.
  """
  @spec hit(atom(), String.t(), pos_integer(), pos_integer(), integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(bucket, id, limit, window_ms, now \\ System.system_time(:millisecond)) do
    window = div(now, window_ms)
    key = {bucket, id, window}
    expires_at = (window + 1) * window_ms
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, expires_at})

    if count > limit do
      {:deny, expires_at - now}
    else
      {:allow, count}
    end
  end

  defp rate_limits, do: Application.get_env(:ctf_server, :rate_limits, [])

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    # Drop every window whose expiry has passed. Position 3 is `expires_at`.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
