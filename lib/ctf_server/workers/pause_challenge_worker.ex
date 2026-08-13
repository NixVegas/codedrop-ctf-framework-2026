defmodule CtfServer.Workers.PauseChallengeAttempt do
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfUtils.VMUtils

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
    Logger.info("Pausing attempt #{attempt_id}")

    attempt = Challenges.get_challenge_attempt!(attempt_id)

    # Power the guest off (freeing host CPU/RAM) and stop it coming back on a
    # host reboot. The domain, overlay, network, and port are all retained so
    # the attempt can be resumed with its disk state intact.
    :ok = VMUtils.set_domain_autostart(attempt.id, false)
    :ok = VMUtils.stop_domain(attempt.id)

    # The status is already :paused (set when the pause was requested); re-affirm
    # and republish so any late listeners converge.
    {:ok, attempt} = Challenges.update_challenge_attempt(attempt, %{status: :paused})
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)

    :ok
  end
end
