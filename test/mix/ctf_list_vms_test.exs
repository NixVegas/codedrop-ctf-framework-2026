defmodule Mix.Tasks.Ctf.ListVmsTest do
  @moduledoc """
  The shell inventory must agree with `/admin/vms`.

  Both read `CtfServer.VMInventory.snapshot/0`; the regression these guard
  against is the task matching domains by the pre-cluster name
  `ctf-vm-<attempt_id>`, which filed every cluster node under "Orphaned" and
  every live attempt as a "Ghost" — actively misleading anyone triaging from
  a shell during the event.

  Libvirt is stubbed (`CtfServer.StubVMBackend`).
  """
  use CtfServer.DataCase, async: true

  import ExUnit.CaptureIO
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.StubVMBackend

  defp run_task do
    capture_io(fn -> Mix.Tasks.Ctf.ListVms.run([]) end)
  end

  defp section(output, title) do
    output
    |> String.split("=== ")
    |> Enum.find(&String.starts_with?(&1, title))
    |> Kernel.||("")
  end

  test "a cluster's per-role nodes list under their attempt, not as orphans" do
    team = team_fixture()
    attempt = challenge_attempt_fixture(%{status: :started, team_id: team.id})

    StubVMBackend.set_domains([
      {"ctf-vm-#{attempt.id}-web", "running"},
      {"ctf-vm-#{attempt.id}-ingress", "running"}
    ])

    StubVMBackend.set_networks([{"ctf-#{attempt.id}", "active"}])

    output = run_task()

    clusters = section(output, "Clusters")
    assert clusters =~ "#{attempt.id}"
    assert clusters =~ "group=basic-nix"
    assert clusters =~ "team=#{team.name} (#{team.id})"
    assert clusters =~ "net=active"
    assert clusters =~ "ingress  ctf-vm-#{attempt.id}-ingress  running"
    assert clusters =~ "web  ctf-vm-#{attempt.id}-web  running"

    assert section(output, "Orphaned") =~ "(none)"
    assert section(output, "Ghost") =~ "(none)"
    assert section(output, "Stray") =~ "(none)"

    assert output =~
             "Summary: 1 cluster(s) / 2 domain(s), 0 ghost, 0 orphaned, 0 stray network(s)"
  end

  test "an in-flight attempt with no domains reports as a ghost" do
    attempt =
      challenge_attempt_fixture(%{status: :provisioning, team_id: team_fixture().id})

    StubVMBackend.set_domains([])
    StubVMBackend.set_networks([])

    output = run_task()

    assert section(output, "Ghost") =~ "#{attempt.id}"
    assert section(output, "Clusters") =~ "(none)"
    assert output =~ "1 ghost"
  end

  test "unclaimed domains and networks report as orphaned/stray" do
    StubVMBackend.set_domains([{"ctf-vm-dead-0000-web", "shut off"}])
    StubVMBackend.set_networks([{"ctf-dead-0000", "active"}, {"default", "active"}])

    output = run_task()

    assert section(output, "Orphaned") =~ "ctf-vm-dead-0000-web  shut off"
    assert section(output, "Stray") =~ "ctf-dead-0000  active"
    refute section(output, "Stray") =~ "default"
    assert output =~ "0 cluster(s) / 0 domain(s), 0 ghost, 1 orphaned, 1 stray network(s)"
  end
end
