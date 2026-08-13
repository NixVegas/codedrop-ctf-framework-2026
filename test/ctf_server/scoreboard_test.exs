defmodule CtfServer.ScoreboardTest do
  use CtfServer.DataCase, async: true

  import CtfServer.AccountsFixtures

  alias CtfServer.ChallengeAttempt
  alias CtfServer.Repo
  alias CtfServer.Scoreboard

  # Captures are inserted directly: going through the real completion path
  # would provision VMs, and all this needs is scored history.
  defp capture(team, minutes_ago, score, opts \\ []) do
    Repo.insert!(%ChallengeAttempt{
      team_id: team.id,
      group: Keyword.get(opts, :group, "basic-nix"),
      level: Keyword.get(opts, :level, 1),
      status: :completed,
      earned_score: score,
      completed_at:
        DateTime.utc_now()
        |> DateTime.add(-minutes_ago * 60, :second)
        |> DateTime.truncate(:microsecond)
    })
  end

  defp series_for(points, name), do: Enum.filter(points, &(&1.team == name))

  describe "timeline/2" do
    test "accumulates a team's captures into a rising step series" do
      team = team_fixture(%{name: "Steppers"})
      capture(team, 30, 100, level: 1)
      capture(team, 20, 150, level: 2)

      {points, series} = Scoreboard.timeline()

      assert [%{name: "Steppers", own?: false}] = series

      scores = points |> series_for("Steppers") |> Enum.map(& &1.score)
      assert List.first(scores) == 0, "the series starts from zero"
      assert List.last(scores) == 250, "the series ends at the running total"
      assert scores == Enum.sort(scores), "cumulative score never decreases"
    end

    test "excludes completions with no timestamp, which can't be placed on an axis" do
      team = team_fixture(%{name: "Undated"})

      Repo.insert!(%ChallengeAttempt{
        team_id: team.id,
        group: "basic-nix",
        level: 1,
        status: :completed,
        earned_score: 500,
        completed_at: nil
      })

      assert {[], []} = Scoreboard.timeline()
    end

    test "caps the chart at the palette's series limit" do
      for i <- 1..(Scoreboard.series_limit() + 3) do
        team = team_fixture(%{name: "Team #{i}"})
        capture(team, 10, i * 10)
      end

      {_points, series} = Scoreboard.timeline()

      assert length(series) == Scoreboard.series_limit()
    end

    test "keeps the top scorers, dropping the rest" do
      winner = team_fixture(%{name: "Winner"})
      capture(winner, 10, 10_000)

      for i <- 1..(Scoreboard.series_limit() + 2) do
        team = team_fixture(%{name: "Also Ran #{i}"})
        capture(team, 10, i)
      end

      {_points, series} = Scoreboard.timeline()
      names = Enum.map(series, & &1.name)

      assert "Winner" in names
      refute "Also Ran 1" in names, "the lowest scorer is cut"
    end

    test "orders series by registration, not by rank, so a lead change can't repaint" do
      first = team_fixture(%{name: "Registered First"})
      second = team_fixture(%{name: "Registered Second"})

      # Second team leads.
      capture(first, 30, 100)
      capture(second, 30, 900)

      {_points, before} = Scoreboard.timeline()
      assert Enum.map(before, & &1.name) == ["Registered First", "Registered Second"]

      # First team overtakes; the series order must not follow.
      capture(first, 5, 5_000, level: 2)

      {_points, after_overtake} = Scoreboard.timeline()
      assert Enum.map(after_overtake, & &1.name) == ["Registered First", "Registered Second"]
    end

    test "every series shares one time axis so a tooltip can report them all" do
      a = team_fixture(%{name: "A"})
      b = team_fixture(%{name: "B"})
      capture(a, 30, 100)
      capture(b, 20, 100)

      {points, _series} = Scoreboard.timeline()

      times_a = points |> series_for("A") |> Enum.map(& &1.at)
      times_b = points |> series_for("B") |> Enum.map(& &1.at)

      assert times_a == times_b
    end

    test "marks only the final point of each series as the edge" do
      team = team_fixture(%{name: "Edged"})
      capture(team, 30, 100)
      capture(team, 10, 100, level: 2)

      {points, _series} = Scoreboard.timeline()
      edges = points |> series_for("Edged") |> Enum.filter(& &1.edge)

      assert length(edges) == 1
      assert List.last(series_for(points, "Edged")).edge
    end
  end

  describe "the competition window bounds the axis" do
    test "starts the axis at the competition start, so every line shares an origin" do
      starts_at =
        DateTime.utc_now() |> DateTime.add(-120 * 60, :second) |> DateTime.truncate(:microsecond)

      {:ok, _} =
        CtfServer.Competition.update(CtfServer.Competition.get(), %{starts_at: starts_at})

      team = team_fixture(%{name: "Late Starter"})
      capture(team, 30, 100)

      {points, _series} = Scoreboard.timeline()
      first = points |> series_for("Late Starter") |> List.first()

      assert DateTime.compare(first.at, starts_at) == :eq
      assert first.score == 0
    end

    test "stops the axis at the competition end rather than trailing to now" do
      starts_at =
        DateTime.utc_now() |> DateTime.add(-120 * 60, :second) |> DateTime.truncate(:microsecond)

      ends_at =
        DateTime.utc_now() |> DateTime.add(-60 * 60, :second) |> DateTime.truncate(:microsecond)

      # Registration closes with the competition, so the team has to exist
      # before the window is set in the past.
      team = team_fixture(%{name: "Finished"})
      capture(team, 90, 100)

      {:ok, _} =
        CtfServer.Competition.update(CtfServer.Competition.get(), %{
          starts_at: starts_at,
          ends_at: ends_at
        })

      {points, _series} = Scoreboard.timeline()
      last = points |> series_for("Finished") |> List.last()

      assert DateTime.compare(last.at, ends_at) == :eq,
             "a finished CTF must not keep growing a flat tail toward the present"
    end
  end

  describe "timeline/2 with a viewing team" do
    test "adds the viewer's own team when it isn't among the leaders" do
      for i <- 1..Scoreboard.series_limit() do
        team = team_fixture(%{name: "Leader #{i}"})
        capture(team, 30, 1_000 + i)
      end

      straggler = team_fixture(%{name: "Straggler"})
      capture(straggler, 20, 5)

      {_points, anonymous} = Scoreboard.timeline()
      refute "Straggler" in Enum.map(anonymous, & &1.name)

      {_points, series} = Scoreboard.timeline(straggler.id)
      own = Enum.filter(series, & &1.own?)

      assert [%{name: "Straggler"}] = own
      assert length(series) == Scoreboard.series_limit() + 1
    end

    test "does not duplicate a viewer who is already a leader" do
      team = team_fixture(%{name: "Leading Viewer"})
      capture(team, 30, 100)

      {_points, series} = Scoreboard.timeline(team.id)

      assert length(series) == 1
      refute Enum.any?(series, & &1.own?), "no separate own-series is needed"
    end

    test "adds nothing for a viewer who has not scored" do
      scorer = team_fixture(%{name: "Scorer"})
      capture(scorer, 30, 100)
      watcher = team_fixture(%{name: "Watcher"})

      {_points, series} = Scoreboard.timeline(watcher.id)

      assert Enum.map(series, & &1.name) == ["Scorer"]
    end
  end

  describe "standings/0" do
    test "sums each team's captures, highest first" do
      big = team_fixture(%{name: "Big"})
      small = team_fixture(%{name: "Small"})
      capture(big, 30, 300)
      capture(big, 20, 200, level: 2)
      capture(small, 10, 50)

      assert [%{name: "Big", current_score: 500}, %{name: "Small", current_score: 50}] =
               Scoreboard.standings()
    end

    test "includes teams that have scored nothing, so they can find themselves" do
      team_fixture(%{name: "Nothing Yet"})

      assert [%{name: "Nothing Yet", current_score: 0}] = Scoreboard.standings()
    end
  end
end
