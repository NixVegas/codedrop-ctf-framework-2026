defmodule CtfServer.Workers.ProvisionChallengeWorkerTest do
  # The provision worker's port-exhaustion handling (F2 / CWE-770 + CWE-755): a
  # full port range must not crash the worker or wedge the attempt in
  # :provisioning. async: false because it shrinks the global :vm_port_range.
  use CtfServer.DataCase, async: false

  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.Challenges
  alias CtfServer.PortManager
  alias CtfServer.Workers.ProvisionChallengeWorker
  alias CtfUtils.PubSubUtils

  setup do
    original = Application.fetch_env!(:ctf_server, :vm_port_range)
    # A single port, so one held attempt exhausts the range.
    Application.put_env(:ctf_server, :vm_port_range, 30_000..30_000)
    on_exit(fn -> Application.put_env(:ctf_server, :vm_port_range, original) end)
    %{team: team_fixture()}
  end

  test "cancels the job and frees the attempt when no VM port is free", %{team: team} do
    # Occupy the only port with an unrelated active attempt.
    holder = challenge_attempt_fixture(%{team_id: team.id, level: 2, status: :provisioning})
    {:ok, _port} = PortManager.checkout_port(holder)

    # A fresh attempt for a real VM challenge, with the range now full.
    attempt =
      challenge_attempt_fixture(%{
        team_id: team.id,
        group: "basic-nix",
        level: 1,
        status: :provisioning
      })

    :ok = PubSubUtils.sub_team_updates(team.id)

    job = %Oban.Job{args: %{"attempt_id" => attempt.id, "pubkey" => "ssh-ed25519 AAAAstub"}}

    # It cancels (no retry) instead of raising a MatchError.
    assert {:cancel, :port_exhausted} = ProvisionChallengeWorker.perform(job)

    # The attempt is deleted, so the challenge is startable again.
    progress = Challenges.get_challenge_progress_for_team(team)
    assert progress[{"basic-nix", 1}].status == :untouched

    # Dashboards are told to refresh.
    assert_receive {:attempt_updated, _id}
  end
end
