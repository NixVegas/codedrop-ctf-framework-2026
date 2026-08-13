defmodule CtfServer.ScoreboardCache do
  @moduledoc """
  Computes the scoreboard once per change, for everyone.

  ## Why this exists

  Every open leaderboard is its own LiveView process. Without this, a single
  flag capture made all of them independently re-query every completed attempt,
  rebuild the timeline, and JSON-encode a ~200KB spec — O(connected clients) of
  identical database and CPU work per capture, at exactly the moment of the
  event when captures come fastest and the most people are watching.

  This process does that work once and hands out the finished artifacts.

  ## Throttling

  A burst of captures collapses into at most one recomputation per
  `@min_interval_ms`. A scoreboard that lags a couple of seconds behind is
  fine; one that melts under a capture storm in the final hour is not. The
  first change after a quiet period is applied immediately, so the common case
  still feels live — only sustained bursts are batched.

  ## Per-viewer specs

  The chart shows the viewer's own team even when it isn't a leader, so the
  spec depends on who is looking. Specs are memoized per team id (plus one for
  logged-out viewers), and every team already in the leaders shares the same
  cached spec as a spectator would. Only teams outside the leaders cost an
  extra encode, and each of those is computed once per refresh rather than once
  per client.
  """
  use GenServer

  alias CtfServer.Scoreboard
  alias CtfServerWeb.ScoreboardChart
  alias CtfUtils.PubSubUtils

  @min_interval_ms 2_000

  # Key used for viewers with no team of their own (logged out, or a team that
  # hasn't scored) — they all share one spec.
  @anonymous :anonymous

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))

  @doc """
  The chart spec for this viewer as encoded JSON, or `nil` when nothing has
  been scored yet.
  """
  def spec_for(team_id \\ nil), do: cached({:spec_for, team_id}, fn -> build_spec(team_id) end)

  @doc "The standings, highest score first, shared by every viewer."
  def standings, do: cached(:standings, &Scoreboard.standings/0)

  # This process is a performance layer, never a correctness one: with it
  # stopped, callers compute the same answer inline. That is what the test
  # environment does — a long-lived process issuing its own queries doesn't hold
  # a checked-out sandbox connection, so it would break every test that touches
  # the database. Tests get the uncached path and the same results.
  defp cached(request, compute) do
    case GenServer.whereis(__MODULE__) do
      nil -> compute.()
      pid -> GenServer.call(pid, request)
    end
  end

  @impl GenServer
  def init(:ok) do
    :ok = PubSubUtils.sub_leaderboard()
    {:ok, %{standings: [], specs: %{}, refreshed_at: nil, pending?: false}, {:continue, :refresh}}
  end

  @impl GenServer
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl GenServer
  def handle_call({:spec_for, team_id}, _from, state) do
    key = team_id || @anonymous

    case Map.fetch(state.specs, key) do
      {:ok, spec} ->
        {:reply, spec, state}

      :error ->
        spec = build_spec(team_id)
        {:reply, spec, put_in(state.specs[key], spec)}
    end
  end

  def handle_call(:standings, _from, state), do: {:reply, state.standings, state}

  @impl GenServer
  def handle_info(:leaderboard_updated, state) do
    since = elapsed_ms(state.refreshed_at)

    cond do
      # Already waiting to catch up — the pending refresh will pick this up.
      state.pending? ->
        {:noreply, state}

      is_nil(state.refreshed_at) or since >= @min_interval_ms ->
        {:noreply, announce(refresh(state))}

      true ->
        Process.send_after(self(), :refresh_now, @min_interval_ms - since)
        {:noreply, %{state | pending?: true}}
    end
  end

  def handle_info(:refresh_now, state) do
    {:noreply, announce(refresh(%{state | pending?: false}))}
  end

  # Recomputes the shared standings and drops every memoized spec, so the next
  # viewer of each kind rebuilds theirs from the new data.
  defp refresh(state) do
    %{
      state
      | standings: Scoreboard.standings(),
        specs: %{},
        refreshed_at: System.monotonic_time(:millisecond)
    }
  end

  defp announce(state) do
    :ok = PubSubUtils.pub_scoreboard_refresh()
    state
  end

  defp build_spec(team_id) do
    case Scoreboard.timeline(team_id) do
      {_points, []} -> nil
      {points, series} -> points |> ScoreboardChart.spec(series) |> Jason.encode!()
    end
  end

  defp elapsed_ms(nil), do: :infinity
  defp elapsed_ms(at), do: System.monotonic_time(:millisecond) - at
end
