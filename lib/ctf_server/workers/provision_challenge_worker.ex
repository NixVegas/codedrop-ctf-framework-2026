defmodule CtfServer.Workers.ProvisionChallengeWorker do
  alias CtfServer.Challenge
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfServer.Repo

  use Oban.Worker,
    max_attempts: 3,
    priority: 0,
    queue: :provision,
    tags: [],
    replace: [],
    unique: false

  def queue(%ChallengeAttempt{} = attempt, pubkey) do
    %{attempt_id: attempt.id, pubkey: pubkey}
    |> new()
    |> Oban.insert()
  end

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id, "pubkey" => pubkey}}) do
    Logger.info("Provisioning attempt #{attempt_id}")

    attempt = Challenges.get_challenge_attempt!(attempt_id) |> Repo.preload(:team)

    {:ok, challenge} = Challenges.get_challenge_by_group_and_level(attempt.group, attempt.level)

    case ensure_port(attempt, attempt_id, challenge) do
      {:ok, attempt} ->
        instantiate(challenge, attempt, attempt_id, pubkey)

      {:cancel, reason} ->
        {:cancel, reason}
    end
  end

  # Resolves the port an attempt's VM needs, or reports that the range is full.
  # Returns `{:ok, attempt}` (reloaded when a port was just assigned) or
  # `{:cancel, :port_exhausted}` once the attempt has been abandoned.
  defp ensure_port(attempt, attempt_id, challenge) do
    cond do
      not Challenges.needs_vm?(challenge) ->
        Logger.info("Attempt #{attempt_id} needs no VM; skipping port checkout")
        {:ok, attempt}

      not is_nil(attempt.port) ->
        # A prior run already checked out a port (e.g. an Oban retry after a
        # partial provision). Reuse it — checking out again would just find our
        # own port in use and exhaust a small range.
        Logger.info("Attempt #{attempt_id} already holds port #{attempt.port}; reusing")
        {:ok, attempt}

      true ->
        Logger.info("Checking out port for attempt #{attempt_id}")
        checkout_port(attempt, attempt_id)
    end
  end

  defp checkout_port(attempt, attempt_id) do
    case CtfServer.PortManager.checkout_port(attempt) do
      {:ok, port} ->
        Logger.info("Got port #{port} for attempt #{attempt_id}")
        # Re-load so the freshly assigned port is visible to instantiation.
        {:ok, Challenges.get_challenge_attempt!(attempt_id) |> Repo.preload(:team)}

      {:error, :exhausted} ->
        # Every VM port is in use. Don't crash or retry into the same wall:
        # abandon the attempt so the team sees it as startable and can try
        # again once another VM is torn down.
        Logger.warning(
          "No free VM port for attempt #{attempt_id}; the port range is exhausted. " <>
            "Abandoning the attempt so the team can retry when capacity frees."
        )

        :ok = Challenges.abandon_attempt_no_capacity(attempt)
        {:cancel, :port_exhausted}
    end
  end

  defp instantiate(challenge, attempt, attempt_id, pubkey) do
    Logger.info(
      "Instantiating challenge #{attempt.group}/#{attempt.level} for attempt #{attempt_id}"
    )

    case Challenge.instantiate_challenge_attempt(challenge, attempt, pubkey) do
      :ok ->
        Logger.info("Challenge instantiated for attempt #{attempt_id}")
        {:ok, attempt} = Challenges.update_challenge_attempt(attempt, %{status: :started})
        :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
        :ok

      {:error, reason} ->
        Logger.error("Failed to instantiate attempt #{attempt_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
