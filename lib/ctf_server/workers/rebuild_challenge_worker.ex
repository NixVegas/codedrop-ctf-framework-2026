defmodule CtfServer.Workers.RebuildChallengeAttempt do
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

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id}}) do
    alias CtfServer.Challenge

    Logger.info("Rebuilding attempt #{attempt_id}")

    case Repo.get(ChallengeAttempt, attempt_id) do
      nil ->
        :ok

      attempt ->
        attempt = Repo.preload(attempt, :team)

        {:ok, challenge} =
          Challenges.get_challenge_by_group_and_level(attempt.group, attempt.level)

        # Teardown: destroy the old VM/network/overlay and drop the record so
        # the SSH port is freed and the "already in progress" guard clears.
        :ok = Challenge.cleanup_challenge_attempt(challenge, attempt)
        {:ok, _} = Challenges.delete_challenge_attempt(attempt)
        :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)

        # Start: provision a fresh instance (new keypair + port). The flag is
        # deterministic per team, so progress is unaffected.
        case Challenges.start_challenge_attempt(attempt.team, attempt.group, attempt.level) do
          {:ok, _new_attempt} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Rebuild of #{attempt.group}/#{attempt.level} could not re-start: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end
end
