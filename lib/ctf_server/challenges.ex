defmodule CtfServer.Challenges do
  import Ecto.Query, warn: false

  alias CtfServer.Audit
  alias CtfServer.Repo
  alias CtfServer.Challenge
  alias CtfServer.ChallengeAttempt
  alias CtfServer.Accounts.Team
  alias CtfServer.Competition

  # Statuses that hold VM resources (a defined domain, an overlay, a port).
  # A paused attempt is stopped but still holds all of these, so it counts as
  # active for teardown/nuke purposes and pins its port.
  @active_statuses [:provisioning, :started, :paused, :deprovisioning]

  # Statuses whose VM is actually running (consuming host CPU/RAM). Only these
  # count against a team's max-concurrent-VMs limit; paused ones do not.
  @running_vm_statuses [:provisioning, :started]

  @doc """
  Gets the available challenge modules as strings.
  """
  def get_available_challenges(),
    do:
      :code.all_available()
      |> Enum.map(fn {module, _, _} -> "#{module}" end)
      |> Enum.filter(fn module ->
        String.starts_with?(module, "Elixir.CtfServer.Challenges.")
      end)
      |> Enum.map(fn challenge_name ->
        String.to_existing_atom(challenge_name) |> struct!()
      end)

  @doc """
  Whether a challenge requires a provisioned VM (and therefore an SSH port).

  Per the `CtfServer.ChallengeBehavior.vm_base_config/0` contract, a challenge
  declares that it needs no VM by returning `nil`. No-VM challenges (e.g. the
  Nix Ecosystem track, which is solved against external resources) skip port
  checkout, and provisioning becomes a metadata-only transition straight to
  `:started`.
  """
  def needs_vm?(challenge), do: not is_nil(challenge.__struct__.vm_base_config())

  @doc """
  The most running VMs a single team may hold at once.

  Configured via `:max_vms_per_team` (default 8); overridable at runtime with
  `CTF_SERVER_MAX_VMS_PER_TEAM`. See `vm_limit_reached?/1`.
  """
  @spec max_vms_per_team() :: non_neg_integer()
  def max_vms_per_team, do: Application.get_env(:ctf_server, :max_vms_per_team, 8)

  @doc """
  Counts the team's attempts whose VM is currently running.

  Running means `:provisioning`/`:started` for a challenge that actually needs
  a VM; paused, torn-down, and no-VM attempts do not count.
  """
  @spec count_running_vms(Team.t()) :: non_neg_integer()
  def count_running_vms(%Team{} = team) do
    from(a in ChallengeAttempt,
      where: a.team_id == ^team.id and a.status in ^@running_vm_statuses,
      select: %{group: a.group, level: a.level}
    )
    |> Repo.all()
    |> Enum.count(fn %{group: group, level: level} ->
      case get_challenge_by_group_and_level(group, level) do
        {:ok, challenge} -> needs_vm?(challenge)
        _ -> false
      end
    end)
  end

  @doc """
  Whether starting/resuming another VM would exceed the team's limit.

  Admin teams are exempt. See `max_vms_per_team/0` and `count_running_vms/1`.
  """
  @spec vm_limit_reached?(Team.t()) :: boolean()
  def vm_limit_reached?(%Team{is_admin: true}), do: false

  def vm_limit_reached?(%Team{} = team) do
    count_running_vms(team) >= max_vms_per_team()
  end

  @doc """
  Gets a map of the challenges for the team, mapping a tuple of their group/level to their state.

  State is one of :untouched, :provisioning, :started, :deprovisioning, :completed

  Example output:
  ```
  %{
    {"group 1", 1} => :untouched,
    {"group 1", 2} => :started,
    {"group 1", 3} => :completed,
    {"group 2", 1} => :untouched
  }
  ```
  """
  def get_challenge_progress_for_team(%Team{} = team) do
    # Step 1: Get available challenges
    available_challenges = get_available_challenges()

    # Step 2: Get recorded challenges for team
    {:ok, attempts} = get_challenge_attempts_for_team(team)

    # Step 3: Reconcile
    Enum.reduce(available_challenges, %{}, fn challenge, acc ->
      group = Challenge.group(challenge)
      level = Challenge.level(challenge)

      Map.put(
        acc,
        {group, level},
        %{
          status:
            case Enum.find(attempts, fn a -> a.level == level and a.group == group end) do
              nil -> :untouched
              attempt -> attempt.status
            end,
          group: group,
          level: level
        }
      )
    end)
  end

  def get_challenge_by_group_and_level(group, level) do
    challenge =
      get_available_challenges()
      |> Enum.find(fn c -> Challenge.group(c) == group && Challenge.level(c) == level end)

    case challenge do
      nil -> {:error, :not_found}
      c -> {:ok, c}
    end
  end

  @doc """
  Returns the list of challenge_attempt.

  ## Examples

      iex> list_challenge_attempt()
      [%ChallengeAttempt{}, ...]

  """
  def list_challenge_attempt do
    Repo.all(ChallengeAttempt) |> Repo.preload(:team)
  end

  @doc """
  Gets a single challenge_attempt.

  Raises `Ecto.NoResultsError` if the Challenge attempt does not exist.

  ## Examples

      iex> get_challenge_attempt!(123)
      %ChallengeAttempt{}

      iex> get_challenge_attempt!(456)
      ** (Ecto.NoResultsError)

  """
  def get_challenge_attempt!(id), do: Repo.get!(ChallengeAttempt, id)

  def get_challenge_attempt_for_team(team, challenge_group, challenge_level) do
    case Repo.get_by(ChallengeAttempt,
           team_id: team.id,
           group: challenge_group,
           level: challenge_level
         ) do
      nil -> {:error, :not_found}
      attempt -> {:ok, attempt}
    end
  end

  def get_challenge_attempts_for_team(team) do
    case Repo.all_by(ChallengeAttempt, team_id: team.id) do
      nil -> {:error, :not_found}
      attempt -> {:ok, attempt}
    end
  end

  @doc """
  Starts a challenge attempt for a team.

  Note that this is responsible for:

  * Generating the flag
  * Scheduling VM provisioning
  """
  def start_challenge_attempt(team, challenge_group, challenge_level) do
    if not Competition.challenges_open?() and not team.is_admin do
      {:error, :competition_closed}
    else
      case get_challenge_attempt_for_team(team, challenge_group, challenge_level) do
        {:ok, _attempt} ->
          {:error, :already_in_progress}

        {:error, :not_found} ->
          {:ok, challenge} = get_challenge_by_group_and_level(challenge_group, challenge_level)

          if needs_vm?(challenge) and vm_limit_reached?(team) do
            {:error, :vm_limit_reached}
          else
            do_start_challenge_attempt(team, challenge, challenge_group, challenge_level)
          end
      end
    end
  end

  # The staff "answer key" stored on the attempt (admin-only; see
  # ChallengeAttempt.flag). Defaults to the single wrapped flag; a challenge with
  # several flags/values overrides via ChallengeBehavior.reference_values/1.
  defp reference_values(challenge, team, base_flag) do
    mod = challenge.__struct__

    if function_exported?(mod, :reference_values, 1) do
      mod.reference_values(team)
    else
      %{"flag" => "Nix{#{base_flag}}"}
    end
  end

  defp do_start_challenge_attempt(team, challenge, challenge_group, challenge_level) do
    {:ok, flag} = Challenge.create_flag(challenge, team)
    {:ok, pubkey, privkey} = CtfUtils.SSHUtils.gen_keypair()

    {:ok, attempt} =
      create_challenge_attempt(%{
        group: challenge_group,
        flag: reference_values(challenge, team, flag),
        level: challenge_level,
        status: :provisioning,
        team_id: team.id,
        privkey: privkey
      })

    {:ok, _job} = CtfServer.Workers.ProvisionChallengeWorker.queue(attempt, pubkey)

    # Announce the brand-new attempt so team dashboards and the admin
    # view pick it up without needing a prior subscription to it.
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    Audit.start_attempt(team, attempt)

    {:ok, attempt}
  end

  @doc """
  Completes a challenge attempt for a team.

  Note that this is responsible for:

  * Generating the flag
  * Scheduling VM provisdeprovisioning
  """
  def complete_challenge_attempt(challenge, team, score) do
    challenge_group = Challenge.group(challenge)
    challenge_level = Challenge.level(challenge)

    case get_challenge_attempt_for_team(team, challenge_group, challenge_level) do
      {:ok, attempt} ->
        {:ok, attempt} =
          update_challenge_attempt(attempt, %{status: :deprovisioning, earned_score: score})

        :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
        {:ok, _job} = CtfServer.Workers.DeprovisionChallengeAttempt.queue(attempt)

        Audit.complete_attempt(team, attempt, score)

        # Best-effort: flash the lights in the space (no-op if unconfigured).
        CtfServer.HomeAssistant.flag_captured(team, challenge_group, challenge_level, score)

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Creates a challenge_attempt.

  ## Examples

      iex> create_challenge_attempt(%{field: value})
      {:ok, %ChallengeAttempt{}}

      iex> create_challenge_attempt(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_challenge_attempt(attrs \\ %{}) do
    %ChallengeAttempt{}
    |> ChallengeAttempt.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a challenge_attempt.

  ## Examples

      iex> update_challenge_attempt(challenge_attempt, %{field: new_value})
      {:ok, %ChallengeAttempt{}}

      iex> update_challenge_attempt(challenge_attempt, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_challenge_attempt(%ChallengeAttempt{} = challenge_attempt, attrs) do
    challenge_attempt
    |> ChallengeAttempt.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a challenge_attempt.

  ## Examples

      iex> delete_challenge_attempt(challenge_attempt)
      {:ok, %ChallengeAttempt{}}

      iex> delete_challenge_attempt(challenge_attempt)
      {:error, %Ecto.Changeset{}}

  """
  def delete_challenge_attempt(%ChallengeAttempt{} = challenge_attempt) do
    Repo.delete(challenge_attempt)
  end

  @doc """
  Abandons an attempt that could not be provisioned because no VM port was free.

  Deletes the attempt (returning the challenge to `:untouched`, the same way a
  teardown does) and announces the change so the team's dashboard refreshes.
  Port checkout fails before any VM, port, or network is allocated, so there is
  nothing to tear down. The team can start the challenge again once capacity
  frees.
  """
  def abandon_attempt_no_capacity(%ChallengeAttempt{} = attempt) do
    {:ok, _} = delete_challenge_attempt(attempt)
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    :ok
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking challenge_attempt changes.

  ## Examples

      iex> change_challenge_attempt(challenge_attempt)
      %Ecto.Changeset{data: %ChallengeAttempt{}}

  """
  def change_challenge_attempt(%ChallengeAttempt{} = challenge_attempt, attrs \\ %{}) do
    ChallengeAttempt.changeset(challenge_attempt, attrs)
  end

  ## Instance management (self-service for teams; admins for any team)

  @doc """
  Lists every attempt currently holding (or supposed to hold) VM resources,
  across all teams, newest first, with `:team` preloaded.

  Attempts of no-VM challenges never hold VM resources and are excluded;
  attempts whose challenge no longer exists are kept (their resources still
  need accounting for).
  """
  def list_vm_attempts_in_flight do
    Repo.all(
      from a in ChallengeAttempt,
        where: a.status in ^@active_statuses,
        order_by: [desc: a.inserted_at],
        preload: :team
    )
    |> Enum.filter(fn a ->
      case get_challenge_by_group_and_level(a.group, a.level) do
        {:ok, challenge} -> needs_vm?(challenge)
        {:error, :not_found} -> true
      end
    end)
  end

  @doc """
  The most recent lifecycle jobs for an attempt, newest first.

  Read straight off `oban_jobs` (which stores the attempt id in `args`) —
  this is the closest thing to a provisioning log the app has, and it is
  what explains a ghost attempt or one wedged in `:provisioning`. Returns
  maps of `worker`, `state`, `attempt` (Oban's try counter), and `errors`.
  """
  def list_jobs_for_attempt(attempt_id, limit \\ 5) do
    Repo.all(
      from j in "oban_jobs",
        where: fragment("?->>'attempt_id' = ?", j.args, ^attempt_id),
        order_by: [desc: j.id],
        limit: ^limit,
        select: %{
          worker: j.worker,
          state: j.state,
          attempt: j.attempt,
          errors: j.errors,
          inserted_at: j.inserted_at
        }
    )
  end

  @doc """
  Lists a team's active challenge instances (attempts that hold VM
  resources), oldest first.
  """
  def list_active_attempts_for_team(%Team{} = team) do
    Repo.all(
      from a in ChallengeAttempt,
        where: a.team_id == ^team.id and a.status in ^@active_statuses,
        order_by: [asc: a.inserted_at]
    )
  end

  @doc """
  Lists all of a team's challenge attempts regardless of status, with active
  instances first and then ordered by challenge group/level.
  """
  def list_attempts_for_team(%Team{} = team) do
    Repo.all(from a in ChallengeAttempt, where: a.team_id == ^team.id)
    |> Enum.sort_by(fn a -> {a.status not in @active_statuses, a.group, a.level} end)
  end

  @doc """
  Forcibly shuts down a challenge attempt's VM.

  The attempt is marked `:deprovisioning` with a score of 0 and the ordinary
  deprovision worker tears the VM down, leaving the attempt `:completed` so
  the team cannot respawn it. Only admins should call this.
  """
  def force_shutdown_attempt(%ChallengeAttempt{} = attempt, actor \\ nil) do
    {:ok, attempt} =
      update_challenge_attempt(attempt, %{status: :deprovisioning, earned_score: 0})

    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    {:ok, _job} = CtfServer.Workers.DeprovisionChallengeAttempt.queue(attempt)

    Audit.force_shutdown_attempt(attempt, actor)

    {:ok, attempt}
  end

  @doc """
  Resets a challenge attempt so the team can start it over.

  The attempt is marked `:deprovisioning` and a worker tears down any VM
  resources, then deletes the attempt record entirely — returning the
  challenge to `:untouched` and freeing the SSH port.
  """
  def reset_challenge_attempt_instance(%ChallengeAttempt{} = attempt, actor \\ nil) do
    {:ok, attempt} = update_challenge_attempt(attempt, %{status: :deprovisioning})
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    {:ok, _job} = CtfServer.Workers.ResetChallengeAttempt.queue(attempt)

    Audit.reset_attempt(attempt, actor)

    {:ok, attempt}
  end

  @doc """
  Tears down a challenge attempt's VM and removes the attempt entirely.

  Same effect as `reset_challenge_attempt_instance/2` — the VM, network, and
  overlay are destroyed, the SSH port is freed, and the attempt record is
  deleted so the challenge returns to `:untouched` — but recorded as a
  self-service teardown. Teams may tear down their own instances; admins may
  tear down any.
  """
  def teardown_challenge_attempt(%ChallengeAttempt{} = attempt, actor \\ nil) do
    {:ok, attempt} = update_challenge_attempt(attempt, %{status: :deprovisioning})
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    {:ok, _job} = CtfServer.Workers.ResetChallengeAttempt.queue(attempt)

    Audit.teardown_attempt(attempt, actor)

    {:ok, attempt}
  end

  @doc """
  Tears down an in-flight attempt at competition end: mark it deprovisioning
  (earned score preserved) and enqueue the deprovision worker. The team cannot
  respawn since the attempt lands :completed.
  """
  def teardown_at_competition_end(%ChallengeAttempt{} = attempt) do
    {:ok, attempt} = update_challenge_attempt(attempt, %{status: :deprovisioning})
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    {:ok, _job} = CtfServer.Workers.DeprovisionChallengeAttempt.queue(attempt)
    {:ok, attempt}
  end

  @doc """
  Rebuilds a challenge attempt: teardown the existing VM, then start a fresh one.

  The old VM/network/overlay are destroyed and the attempt is provisioned
  again from a clean base image (new keypair and SSH port). Progress and flag
  are unaffected — flags are deterministic per team. Returns `{:ok, attempt}`
  with the attempt marked `:deprovisioning` while the rebuild worker runs.
  """
  def rebuild_challenge_attempt(%ChallengeAttempt{} = attempt, actor \\ nil) do
    {:ok, attempt} = update_challenge_attempt(attempt, %{status: :deprovisioning})
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    {:ok, _job} = CtfServer.Workers.RebuildChallengeAttempt.queue(attempt)

    Audit.rebuild_attempt(attempt, actor)

    {:ok, attempt}
  end

  @doc """
  Pauses a running challenge attempt.

  The guest is powered off (freeing host CPU/RAM) and its autostart is
  disabled, but the domain, overlay, network, and SSH port are all retained so
  the attempt can be resumed with its disk state intact. The attempt moves to
  `:paused`, which does not count against the team's running-VM limit.

  Only `:started` attempts can be paused; any other status returns
  `{:error, :invalid_state}`.
  """
  def pause_challenge_attempt(attempt, actor \\ nil)

  def pause_challenge_attempt(%ChallengeAttempt{status: :started} = attempt, actor) do
    {:ok, attempt} = update_challenge_attempt(attempt, %{status: :paused})
    :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
    {:ok, _job} = CtfServer.Workers.PauseChallengeAttempt.queue(attempt)

    Audit.pause_attempt(attempt, actor)

    {:ok, attempt}
  end

  def pause_challenge_attempt(%ChallengeAttempt{}, _actor), do: {:error, :invalid_state}

  @doc """
  Resumes a paused challenge attempt.

  The guest is powered back on and its autostart re-enabled. Because the VM
  will be running again this is subject to the team's running-VM limit
  (`vm_limit_reached?/1`); admins are exempt. Returns
  `{:error, :vm_limit_reached}` if the team is at its limit, otherwise
  `{:ok, attempt}` with the attempt moving back through `:provisioning`.

  Only `:paused` attempts can be resumed; any other status returns
  `{:error, :invalid_state}`.
  """
  def resume_challenge_attempt(attempt, actor \\ nil)

  def resume_challenge_attempt(%ChallengeAttempt{status: :paused} = attempt, actor) do
    team = Repo.preload(attempt, :team).team

    if vm_limit_reached?(team) do
      {:error, :vm_limit_reached}
    else
      {:ok, attempt} = update_challenge_attempt(attempt, %{status: :provisioning})
      :ok = CtfUtils.PubSubUtils.pub_attempt_update(attempt)
      {:ok, _job} = CtfServer.Workers.ResumeChallengeAttempt.queue(attempt)

      Audit.resume_attempt(attempt, actor)

      {:ok, attempt}
    end
  end

  def resume_challenge_attempt(%ChallengeAttempt{}, _actor), do: {:error, :invalid_state}

  @doc """
  Force-shuts every instance a team has that still holds VM resources.

  Attempts already `:deprovisioning` are left to their in-flight workers.
  Returns the attempts that were shut down.
  """
  def kill_active_attempts_for_team(%Team{} = team, actor \\ nil) do
    killed =
      for attempt <- list_active_attempts_for_team(team),
          attempt.status in [:provisioning, :started, :paused] do
        {:ok, attempt} = force_shutdown_attempt(attempt, actor)
        attempt
      end

    {:ok, killed}
  end
end
