defmodule CtfServer.CompetitionSweeperTest do
  use CtfServer.DataCase, async: false
  use Oban.Testing, repo: CtfServer.Repo

  import CtfServer.AccountsFixtures

  alias CtfServer.Challenges
  alias CtfServer.Competition
  alias CtfServer.Repo
  alias CtfServer.Workers.CompetitionSweeper
  alias CtfServer.Workers.DeprovisionChallengeAttempt

  # A VM-backed challenge that exists in the test env; needs_vm? is true so
  # it shows up in Challenges.list_vm_attempts_in_flight/0.
  @vm_group "basic-nix"

  defp attempt_fixture(team) do
    {:ok, attempt} =
      Challenges.create_challenge_attempt(%{
        group: @vm_group,
        level: 1,
        status: :started,
        team_id: team.id
      })

    attempt
  end

  describe "perform/1 after the competition window has ended" do
    test "tears down an in-flight VM attempt and enqueues the deprovision worker" do
      team = team_fixture()
      attempt = attempt_fixture(team)

      {:ok, _competition} =
        Competition.update(Competition.get(), %{
          starts_at: ~U[2020-01-01 00:00:00Z],
          ends_at: ~U[2020-01-02 00:00:00Z]
        })

      assert :ok = CompetitionSweeper.perform(%Oban.Job{})

      assert Repo.reload!(attempt).status == :deprovisioning

      assert_enqueued(
        worker: DeprovisionChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )
    end
  end

  describe "perform/1 while the competition window is open" do
    test "leaves in-flight VM attempts alone" do
      team = team_fixture()
      attempt = attempt_fixture(team)

      assert :ok = CompetitionSweeper.perform(%Oban.Job{})

      assert Repo.reload!(attempt).status == :started
      refute_enqueued(worker: DeprovisionChallengeAttempt)
    end
  end
end
