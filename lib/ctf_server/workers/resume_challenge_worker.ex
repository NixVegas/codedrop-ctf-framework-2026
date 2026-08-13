defmodule CtfServer.Workers.ResumeChallengeAttempt do
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfUtils.VMUtils

  use Oban.Worker,
    max_attempts: 3,
    priority: 0,
    queue: :provision,
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
    Logger.info("Resuming attempt #{attempt_id}")

    attempt = Challenges.get_challenge_attempt!(attempt_id)

    # Power the (still-defined) guest back on and re-arm autostart so it
    # survives a host reboot again.
    case VMUtils.start_domain(attempt.id) do
      :ok ->
        :ok = VMUtils.set_domain_autostart(attempt.id, true)
        {:ok, attempt} = Challenges.update_challenge_attempt(attempt, %{status: :started})
        :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
        :ok

      {:error, reason} ->
        Logger.error("Failed to resume attempt #{attempt_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
