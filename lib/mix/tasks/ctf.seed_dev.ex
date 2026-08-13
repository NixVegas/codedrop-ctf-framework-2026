defmodule Mix.Tasks.Ctf.SeedDev do
  @shortdoc "Seeds demo teams and solved challenges for local development"
  @moduledoc """
      mix ctf.seed_dev [--teams N] [--hours H] [--reset] [--clean]

  Fills a development database with enough believable history to look at the
  scoreboard, the leaderboard chart, and the admin screens without playing
  through a CTF by hand.

  It creates N demo teams and, for each, a run of *completed* challenge
  attempts spread over the last H hours, drawn from the challenges this build
  actually registers. Teams solve at different rates, so the chart gets
  overtakes and gaps rather than parallel lines.

    * `--teams N` — how many demo teams (default 6)
    * `--hours H` — how many hours of history to spread captures over (default 6)
    * `--reset`   — delete existing demo data first, then seed
    * `--clean`   — delete existing demo data and stop

  ## Safety

  This task refuses to run outside `MIX_ENV=dev`. It writes fabricated teams
  and completed attempts, which in production would be indistinguishable from
  real scoring — so the guard is a hard failure, not a prompt.

  Everything it creates is marked by the `@demo_domain` email domain, which is
  what `--reset`/`--clean` match on. Real teams are never touched.

  Attempts are inserted directly rather than through
  `Challenges.start_challenge_attempt/3`: the point is history, and going
  through the real path would provision live VMs for every seeded row.
  """
  use Mix.Task

  import Ecto.Query

  alias CtfServer.Accounts.Team
  alias CtfServer.Audit
  alias CtfServer.Challenge
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfServer.Repo

  # Every seeded team's email ends in this, and nothing else does. It is the
  # only handle --reset/--clean use, so a mistyped filter can't reach a real team.
  @demo_domain "seed.invalid"

  @names ~w(Nixperts DerivationNation FlakeFatale SegfaultSociety RootCause
            HashCollision StoreCorruption LazyEvaluators PureFunctions ClosureCall)

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :dev do
      Mix.raise("""
      mix ctf.seed_dev only runs in dev (MIX_ENV=#{Mix.env()}).

      It inserts fabricated teams and completed challenge attempts, which
      outside dev would be indistinguishable from real scoring.
      """)
    end

    {opts, _rest, _} =
      OptionParser.parse(args,
        strict: [teams: :integer, hours: :integer, reset: :boolean, clean: :boolean]
      )

    CtfServer.MixHelpers.start_app_insert_only()

    # Audit writes are fire-and-forget through a Task by default, and a mix task
    # exits the moment its work returns — which would drop most of the events
    # the activity feed is supposed to show. Write them inline instead.
    Application.put_env(
      :ctf_server,
      Audit,
      Keyword.put(Application.get_env(:ctf_server, Audit, []), :sync, true)
    )

    cond do
      opts[:clean] ->
        clean()

      true ->
        if opts[:reset], do: clean()
        seed(opts[:teams] || 6, opts[:hours] || 6)
    end
  end

  defp clean do
    demo = from(t in Team, where: like(t.email, ^"%@#{@demo_domain}"))
    team_ids = Repo.all(from t in demo, select: t.id)

    {attempts, _} = Repo.delete_all(from a in ChallengeAttempt, where: a.team_id in ^team_ids)
    {teams, _} = Repo.delete_all(from t in Team, where: t.id in ^team_ids)

    Mix.shell().info("Removed #{teams} demo team(s) and #{attempts} attempt(s).")
  end

  defp seed(team_count, hours) do
    challenges = Challenges.get_available_challenges()

    if challenges == [] do
      Mix.raise("No challenges are registered — nothing to seed attempts from.")
    end

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started_at = DateTime.add(now, -hours * 3600, :second)

    open_competition_window(started_at)

    total =
      @names
      |> Enum.take(team_count)
      |> Enum.with_index()
      |> Enum.map(fn {name, index} ->
        team = create_team(name, index)
        count = seed_attempts(team, index, challenges, started_at, now)
        Mix.shell().info("  #{name}: #{count} solved")
        count
      end)
      |> Enum.sum()

    Mix.shell().info("""

    Seeded #{min(team_count, length(@names))} demo team(s), #{total} completed attempt(s) \
    over the last #{hours}h.
    Log in as any of them with password: #{password()}
    Remove them again with: mix ctf.seed_dev --clean\
    """)
  end

  # The scoreboard is hidden before the competition opens, so a seeded database
  # would show an empty page. Widen the window to cover the seeded history.
  defp open_competition_window(started_at) do
    competition = CtfServer.Competition.get()

    if is_nil(competition.starts_at) or
         DateTime.compare(competition.starts_at, started_at) == :gt do
      {:ok, _} = CtfServer.Competition.update(competition, %{starts_at: started_at})
    end
  end

  defp create_team(name, index) do
    %Team{}
    |> Team.registration_changeset(%{
      name: name,
      email: "demo-#{index}@#{@demo_domain}",
      password: password()
    })
    |> Team.confirm_changeset()
    |> Repo.insert!()
  end

  defp password, do: "seeded-demo-password-1234"

  # Each team gets a different slice of the challenge list and a different
  # cadence, so the lines diverge, cross, and finish at different totals rather
  # than marching in parallel.
  defp seed_attempts(team, index, challenges, started_at, now) do
    solve_count = max(1, div(length(challenges) * (10 - index), 14))
    span = DateTime.diff(now, started_at)

    challenges
    |> Enum.shuffle()
    |> Enum.take(solve_count)
    |> Enum.with_index()
    |> Enum.each(fn {challenge, position} ->
      # Spread captures across the window, with a per-team offset so two teams
      # never score at exactly the same instant.
      fraction = (position + 1) / (solve_count + 1)
      offset = trunc(span * fraction) + index * 37

      completed_at =
        started_at
        |> DateTime.add(min(offset, span), :second)
        |> DateTime.truncate(:microsecond)

      Repo.insert!(%ChallengeAttempt{
        team_id: team.id,
        group: Challenge.group(challenge),
        level: Challenge.level(challenge),
        status: :completed,
        earned_score: Challenge.max_score(challenge),
        completed_at: completed_at,
        flag: %{"flag" => "Nix{seeded-demo}"}
      })

      audit_activity(team, challenge, completed_at, position)
    end)

    solve_count
  end

  # The attempts above are inserted straight into the table, which leaves no
  # trace in the audit log — so the activity feed would have nothing to show.
  # Write the matching events by hand, backdated to line up with the capture.
  defp audit_activity(team, challenge, completed_at, position) do
    group = Challenge.group(challenge)
    level = Challenge.level(challenge)
    started_at = DateTime.add(completed_at, -(4 * 60), :second)

    Audit.audit("challenge", "start", team, started_at, %{group: group, level: level})

    # Every few solves, a miss on the way — the feed is more honest, and more
    # interesting to look at, with failures in it. Never a real flag: this is
    # the placeholder the seeder uses everywhere.
    if rem(position, 3) == 0 do
      Audit.audit("challenge", "submit_flag_failed", team, DateTime.add(completed_at, -60), %{
        group: group,
        level: level,
        flag: "Nix{seeded-demo-wrong}",
        reason: "incorrect"
      })
    end

    Audit.audit("challenge", "complete", team, completed_at, %{
      group: group,
      level: level,
      score: Challenge.max_score(challenge)
    })
  end
end
