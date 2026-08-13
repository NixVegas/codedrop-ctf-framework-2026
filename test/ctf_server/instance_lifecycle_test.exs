defmodule CtfServer.InstanceLifecycleTest do
  # async: false — the limit tests mutate the :max_vms_per_team application env.
  use CtfServer.DataCase, async: false
  use Oban.Testing, repo: CtfServer.Repo

  import CtfServer.AccountsFixtures

  alias CtfServer.ChallengeAttempt
  alias CtfServer.Challenges
  alias CtfServer.Repo

  alias CtfServer.Workers.PauseChallengeAttempt
  alias CtfServer.Workers.RebuildChallengeAttempt
  alias CtfServer.Workers.ResetChallengeAttempt
  alias CtfServer.Workers.ResumeChallengeAttempt

  # Challenges that exist in the test env. Two VM-backed ones are needed to
  # hold more than one running VM without inventing a second attempt at the
  # same challenge, which the app never produces.
  @vm_group "basic-nix"
  @vm_group_b "capture-the-poll"
  @no_vm_group "nix-ecosystem"

  defp attempt_fixture(team, attrs) do
    {:ok, attempt} =
      Challenges.create_challenge_attempt(
        Map.merge(%{group: @vm_group, level: 1, status: :started, team_id: team.id}, attrs)
      )

    attempt
  end

  defp set_limit(n) do
    prev = Application.get_env(:ctf_server, :max_vms_per_team)
    Application.put_env(:ctf_server, :max_vms_per_team, n)
    on_exit(fn -> Application.put_env(:ctf_server, :max_vms_per_team, prev) end)
  end

  describe "count_running_vms/1 and vm_limit_reached?/1" do
    test "counts only running VM-backed attempts (not paused or no-VM)" do
      team = team_fixture()
      attempt_fixture(team, %{group: @vm_group, level: 1, status: :started})
      attempt_fixture(team, %{group: @vm_group_b, level: 1, status: :paused})
      attempt_fixture(team, %{group: @no_vm_group, level: 1, status: :started})

      assert Challenges.count_running_vms(team) == 1
    end

    test "a non-admin team reaches the limit; an admin never does" do
      set_limit(2)
      team = team_fixture()
      admin = admin_team_fixture()

      refute Challenges.vm_limit_reached?(team)
      attempt_fixture(team, %{group: @vm_group, level: 1, status: :started})
      attempt_fixture(team, %{group: @vm_group_b, level: 1, status: :started})
      assert Challenges.vm_limit_reached?(team)

      for group <- [@vm_group, @vm_group_b],
          do: attempt_fixture(admin, %{group: group, level: 1, status: :started})

      refute Challenges.vm_limit_reached?(admin)
    end
  end

  describe "start_challenge_attempt/3 limit enforcement" do
    test "refuses a new VM attempt when the team is at its limit" do
      set_limit(1)
      team = team_fixture()
      attempt_fixture(team, %{group: @vm_group, level: 1, status: :started})

      assert {:error, :vm_limit_reached} =
               Challenges.start_challenge_attempt(team, @vm_group_b, 1)
    end

    test "admins bypass the limit" do
      set_limit(1)
      admin = admin_team_fixture()
      attempt_fixture(admin, %{group: @vm_group, level: 1, status: :started})

      assert {:ok, %ChallengeAttempt{}} =
               Challenges.start_challenge_attempt(admin, @vm_group_b, 1)
    end

    test "the limit does not apply to no-VM challenges" do
      set_limit(1)
      team = team_fixture()
      attempt_fixture(team, %{group: @vm_group, level: 1, status: :started})

      assert {:ok, %ChallengeAttempt{}} =
               Challenges.start_challenge_attempt(team, @no_vm_group, 1)
    end
  end

  describe "pause_challenge_attempt/2" do
    test "pausing a started attempt marks it paused and enqueues the worker" do
      team = team_fixture()
      attempt = attempt_fixture(team, %{status: :started})

      assert {:ok, paused} = Challenges.pause_challenge_attempt(attempt)
      assert paused.status == :paused
      assert Repo.reload!(attempt).status == :paused
      assert_enqueued(worker: PauseChallengeAttempt, args: %{attempt_id: attempt.id})
    end

    test "pausing a non-started attempt is rejected" do
      team = team_fixture()
      attempt = attempt_fixture(team, %{status: :paused})

      assert {:error, :invalid_state} = Challenges.pause_challenge_attempt(attempt)
    end
  end

  describe "resume_challenge_attempt/2" do
    test "resuming a paused attempt moves it to provisioning and enqueues the worker" do
      team = team_fixture()
      attempt = attempt_fixture(team, %{status: :paused})

      assert {:ok, resumed} = Challenges.resume_challenge_attempt(attempt)
      assert resumed.status == :provisioning
      assert_enqueued(worker: ResumeChallengeAttempt, args: %{attempt_id: attempt.id})
    end

    test "resuming is refused when the team is at its running-VM limit" do
      set_limit(1)
      team = team_fixture()
      attempt_fixture(team, %{group: @vm_group, level: 1, status: :started})
      paused = attempt_fixture(team, %{group: @vm_group, level: 2, status: :paused})

      assert {:error, :vm_limit_reached} = Challenges.resume_challenge_attempt(paused)
      assert Repo.reload!(paused).status == :paused
      refute_enqueued(worker: ResumeChallengeAttempt)
    end

    test "resuming a non-paused attempt is rejected" do
      team = team_fixture()
      attempt = attempt_fixture(team, %{status: :started})

      assert {:error, :invalid_state} = Challenges.resume_challenge_attempt(attempt)
    end
  end

  describe "teardown_challenge_attempt/2 and rebuild_challenge_attempt/2" do
    test "teardown marks the attempt deprovisioning and enqueues a reset" do
      team = team_fixture()
      attempt = attempt_fixture(team, %{status: :started})

      assert {:ok, torn} = Challenges.teardown_challenge_attempt(attempt)
      assert torn.status == :deprovisioning
      assert_enqueued(worker: ResetChallengeAttempt, args: %{attempt_id: attempt.id})
    end

    test "rebuild marks the attempt deprovisioning and enqueues a rebuild" do
      team = team_fixture()
      attempt = attempt_fixture(team, %{status: :started})

      assert {:ok, rebuilt} = Challenges.rebuild_challenge_attempt(attempt)
      assert rebuilt.status == :deprovisioning
      assert_enqueued(worker: RebuildChallengeAttempt, args: %{attempt_id: attempt.id})
    end
  end
end
