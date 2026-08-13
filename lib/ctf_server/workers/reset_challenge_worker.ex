defmodule CtfServer.Workers.ResetChallengeAttempt do
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

    case Repo.get(ChallengeAttempt, attempt_id) do
      nil ->
        :ok

      attempt ->
        attempt = Repo.preload(attempt, :team)

        {:ok, challenge} =
          Challenges.get_challenge_by_group_and_level(attempt.group, attempt.level)

        :ok = Challenge.cleanup_challenge_attempt(challenge, attempt)

        {:ok, _} = Challenges.delete_challenge_attempt(attempt)

        :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
        # Removing a completed attempt changes the score totals.
        :ok = CtfUtils.PubSubUtils.pub_leaderboard_update()

        :ok
    end
  end
end
