defmodule CtfServer.NoVmChallengeTest do
  use CtfServer.DataCase

  import CtfServer.AccountsFixtures

  alias CtfServer.Challenges
  alias CtfServer.Challenges.BasicNix1
  alias CtfServer.Challenges.TestNoVmChallenge
  alias CtfServer.Repo
  alias CtfServer.Workers.DeprovisionChallengeAttempt
  alias CtfServer.Workers.ProvisionChallengeWorker

  describe "needs_vm?/1" do
    test "true for a challenge whose vm_base_config returns a config" do
      assert Challenges.needs_vm?(struct!(BasicNix1))
    end

    test "false for a challenge whose vm_base_config returns nil" do
      refute Challenges.needs_vm?(struct!(TestNoVmChallenge))
    end
  end

  describe "provisioning a no-VM challenge" do
    setup do
      team = team_fixture()

      {:ok, attempt} =
        Challenges.create_challenge_attempt(%{
          group: TestNoVmChallenge.group(),
          level: TestNoVmChallenge.level(),
          status: :provisioning,
          team_id: team.id
        })

      %{team: team, attempt: attempt}
    end

    test "starts without checking out a port", %{attempt: attempt} do
      assert :ok =
               ProvisionChallengeWorker.perform(%Oban.Job{
                 args: %{"attempt_id" => attempt.id, "pubkey" => "ssh-ed25519 AAAA test"}
               })

      attempt = Repo.reload!(attempt)
      assert attempt.status == :started
      assert is_nil(attempt.port)
    end

    test "deprovisions straight to completed without VM teardown", %{attempt: attempt} do
      {:ok, attempt} = Challenges.update_challenge_attempt(attempt, %{status: :deprovisioning})

      assert :ok =
               DeprovisionChallengeAttempt.perform(%Oban.Job{
                 args: %{"attempt_id" => attempt.id}
               })

      assert Repo.reload!(attempt).status == :completed
    end
  end
end
