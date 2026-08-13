defmodule CtfServer.Scoreboard do
  @moduledoc """
  Score-over-time data for the leaderboard chart.

  A team's score is a step function: it holds flat between captures and jumps by
  `earned_score` the moment an attempt is completed. `timeline/1` returns exactly
  those jump points, which is why the chart draws a step line rather than a
  smooth one — interpolating between captures would draw score a team never had.

  ## Series selection and color stability

  The chart shows at most `series_limit/0` teams because the categorical palette
  has eight slots and cycling hues would make two teams share a color.

  Which teams are shown is decided by rank (top scorers), but the order the
  series come back in is **registration order, never rank**. Color follows the
  entity: a lead change mid-event must not repaint both teams' lines, which is
  what would happen if slot 1 always meant "whoever is winning". Teams only
  change color when they enter or leave the displayed set.
  """

  import Ecto.Query, warn: false

  alias CtfServer.Accounts.Team
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Repo

  # Sixteen series on eight hues: the palette's slots are reused, with a solid
  # or dashed line telling each pair apart. See `CtfServerWeb.ScoreboardChart`
  # for why that is composite encoding rather than a cycled palette.
  @series_limit 16

  @doc "How many teams the chart draws. Bounded by the categorical palette."
  def series_limit, do: @series_limit

  @doc """
  Every team's total score, highest first, for the standings table.

  Sums in the database rather than loading every attempt and reducing in
  Elixir. Teams that have scored nothing are included with a zero, so a team
  can always find itself in the table even before its first capture.
  """
  def standings do
    totals =
      from(a in ChallengeAttempt,
        where: a.status == :completed,
        group_by: a.team_id,
        select: {a.team_id, sum(a.earned_score)}
      )
      |> Repo.all()
      |> Map.new()

    from(t in Team, select: %{id: t.id, name: t.name})
    |> Repo.all()
    |> Enum.map(fn team ->
      %{name: team.name, current_score: Map.get(totals, team.id, 0) || 0}
    end)
    |> Enum.sort_by(& &1.current_score, :desc)
  end

  @doc """
  Cumulative score per team over time, as a flat list of points ready for the
  chart's `values` array.

  Each entry is `%{team: name, at: DateTime, score: cumulative}`. Every shown
  team gets a zero point at `from` so its line starts at the origin rather than
  at its first capture, and a point at `now` so the line runs to the present
  instead of stopping at the last capture.

  Returns `{points, team_names}` where `team_names` is in the stable
  registration order the caller should use for color assignment.
  """
  def timeline(viewer_team_id \\ nil, now \\ DateTime.utc_now()) do
    completions = completions()
    leaders = shown_teams(completions)
    viewer = viewer_series(viewer_team_id, leaders, completions)
    shown = leaders ++ viewer

    competition = CtfServer.Competition.get()
    times = axis_times(completions, shown, competition.starts_at, right_edge(competition, now))
    own_ids = MapSet.new(viewer, & &1.id)

    points =
      Enum.flat_map(shown, fn team ->
        series_points(
          team,
          Map.get(completions, team.id, []),
          times,
          MapSet.member?(own_ids, team.id)
        )
      end)

    series =
      Enum.map(shown, fn team ->
        %{name: team.name, own?: MapSet.member?(own_ids, team.id)}
      end)

    {points, series}
  end

  # The viewing team always appears, even when it isn't among the leaders —
  # a scoreboard that can't show you your own line is useless to most of the
  # field. It's returned separately because it is drawn as a ninth series in
  # neutral ink rather than being given a categorical hue: the palette has
  # eight slots and cycling one would make two teams share a color.
  #
  # A team already in the leaders, or one with nothing scored yet, adds nothing.
  defp viewer_series(nil, _leaders, _completions), do: []

  defp viewer_series(viewer_team_id, leaders, completions) do
    already_shown? = Enum.any?(leaders, &(&1.id == viewer_team_id))
    scored? = Map.has_key?(completions, viewer_team_id)

    if already_shown? or not scored? do
      []
    else
      case Repo.get(Team, viewer_team_id) do
        nil -> []
        team -> [team]
      end
    end
  end

  # Completed attempts that actually scored, grouped by team and ordered in
  # time. An attempt completed before `completed_at` existed (or reset by an
  # admin) has a nil timestamp and can't be placed on an axis, so it's excluded
  # from the chart — it still counts in the leaderboard table's total.
  defp completions do
    from(a in ChallengeAttempt,
      join: t in assoc(a, :team),
      where: a.status == :completed and not is_nil(a.completed_at),
      order_by: [asc: a.completed_at],
      select: %{team_id: a.team_id, at: a.completed_at, earned: a.earned_score}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.team_id)
  end

  # Top scorers by total, then re-sorted into registration order so the caller's
  # color assignment is stable across rank changes.
  defp shown_teams(completions) do
    totals =
      Map.new(completions, fn {team_id, entries} ->
        {team_id, Enum.reduce(entries, 0, &(&1.earned + &2))}
      end)

    ids =
      totals
      |> Enum.sort_by(fn {_id, total} -> -total end)
      |> Enum.take(@series_limit)
      |> Enum.map(fn {id, _total} -> id end)

    case ids do
      [] -> []
      ids -> Repo.all(from t in Team, where: t.id in ^ids, order_by: [asc: t.inserted_at])
    end
  end

  # The x axis runs to the current moment while the CTF is on, but stops dead at
  # `ends_at` once it is over — otherwise every line grows a flat tail that gets
  # longer the more days pass since the event, squeezing the actual competition
  # into a sliver on the left.
  defp right_edge(%{ends_at: nil}, now), do: now

  defp right_edge(%{ends_at: ends_at}, now) do
    if DateTime.compare(now, ends_at) == :gt, do: ends_at, else: now
  end

  # One shared, sorted time axis for every series: the origin, every capture by
  # a shown team, and the right edge.
  #
  # Every team gets a point at every one of these times, rather than only at its
  # own captures. That costs `teams × times` points, and buys two things: the
  # step line is exact, and the chart's tooltip can report every team's score at
  # the hovered instant — a sparse series has no value to report at a time when
  # some *other* team scored.
  defp axis_times(completions, shown, origin, now) do
    captures =
      shown
      |> Enum.flat_map(fn team -> Map.get(completions, team.id, []) end)
      |> Enum.map(& &1.at)

    [origin_at(captures, origin, now), now | captures]
    |> Enum.uniq()
    |> Enum.sort(DateTime)
  end

  # Anchor the zero point to the competition start when there is one, so every
  # line shares an origin. Without a start bound — or with one set after the
  # fact, later than a capture already recorded — fall back to the earliest
  # capture, since a later origin would draw the lines backwards.
  defp origin_at([], _origin, now), do: now

  defp origin_at(captures, origin, _now) do
    earliest = Enum.min(captures, DateTime)

    # Strictly *before* the first capture, never equal to it: a point at the
    # same instant already counts that capture, so the line would open at the
    # first team's score instead of rising from zero.
    fallback = DateTime.add(earliest, -1, :second)

    case origin do
      %DateTime{} = origin ->
        if DateTime.compare(origin, earliest) == :lt, do: origin, else: fallback

      nil ->
        fallback
    end
  end

  # Walk the shared axis carrying the running total, consuming this team's
  # captures as their timestamps are passed. `edge` marks the last point, which
  # is where the chart puts the end marker and the direct label.
  defp series_points(team, entries, times, own?) do
    last = List.last(times)

    {points, _remaining, _total} =
      Enum.reduce(times, {[], entries, 0}, fn time, {acc, remaining, total} ->
        {reached, rest} =
          Enum.split_while(remaining, &(DateTime.compare(&1.at, time) != :gt))

        total = Enum.reduce(reached, total, &(&1.earned + &2))

        point = %{team: team.name, at: time, score: total, edge: time == last, own: own?}
        {[point | acc], rest, total}
      end)

    Enum.reverse(points)
  end
end
