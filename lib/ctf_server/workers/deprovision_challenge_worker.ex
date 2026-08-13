defmodule CtfServer.Workers.DeprovisionChallengeAttempt do
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfServer.Repo

  use Oban.Worker,
    max_attempts: 3,
    priority: 0,
    queue: :deprovision,
    tags: [],
    replace: [],
    unique: false

  def queue(%ChallengeAttempt{} = attempt) do
    %{attempt_id: attempt.id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id}}) do
    alias CtfServer.Challenge

    attempt = Challenges.get_challenge_attempt!(attempt_id) |> Repo.preload(:team)

    {:ok, challenge} = Challenges.get_challenge_by_group_and_level(attempt.group, attempt.level)

    :ok = Challenge.cleanup_challenge_attempt(challenge, attempt)

    {:ok, attempt} = Challenges.update_challenge_attempt(attempt, %{status: :completed})

    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    # A completion changes the score totals.
    :ok = CtfUtils.PubSubUtils.pub_leaderboard_update()

    :ok
  end
end
