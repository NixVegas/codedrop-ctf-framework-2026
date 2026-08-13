defmodule CtfServer.PortManagerTest do
  # DB-backed VM port allocation, including the exhaustion path the provision
  # worker must handle without crashing (F2 / CWE-770). async: false because it
  # shrinks the global :vm_port_range so exhaustion is reachable in a few calls.
  use CtfServer.DataCase, async: false

  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.Challenges
  alias CtfServer.PortManager

  setup do
    original = Application.fetch_env!(:ctf_server, :vm_port_range)
    Application.put_env(:ctf_server, :vm_port_range, 30_000..30_001)
    on_exit(fn -> Application.put_env(:ctf_server, :vm_port_range, original) end)
    %{team: team_fixture()}
  end

  defp provisioning_attempt(team, level) do
    challenge_attempt_fixture(%{team_id: team.id, level: level, status: :provisioning})
  end

  test "assigns free ports until the range is exhausted, then fails cleanly", %{team: team} do
    a1 = provisioning_attempt(team, 1)
    a2 = provisioning_attempt(team, 2)
    a3 = provisioning_attempt(team, 3)

    assert {:ok, p1} = PortManager.checkout_port(a1)
    assert {:ok, p2} = PortManager.checkout_port(a2)
    assert p1 in 30_000..30_001
    assert p2 in 30_000..30_001
    assert p1 != p2

    # Both ports are held by active attempts: the third checkout returns an
    # error tuple rather than raising.
    assert {:error, :exhausted} = PortManager.checkout_port(a3)
  end

  test "persists the assigned port on the attempt", %{team: team} do
    attempt = provisioning_attempt(team, 1)
    assert {:ok, port} = PortManager.checkout_port(attempt)
    assert Challenges.get_challenge_attempt!(attempt.id).port == port
  end

  test "a port frees once its attempt leaves an active status", %{team: team} do
    a1 = provisioning_attempt(team, 1)
    a2 = provisioning_attempt(team, 2)
    a3 = provisioning_attempt(team, 3)

    {:ok, _} = PortManager.checkout_port(a1)
    {:ok, _} = PortManager.checkout_port(a2)
    assert {:error, :exhausted} = PortManager.checkout_port(a3)

    # Only :provisioning/:started/:paused/:deprovisioning count as in use, so
    # completing a1 releases its port for a3.
    {:ok, _} = Challenges.update_challenge_attempt(a1, %{status: :completed})
    assert {:ok, _port} = PortManager.checkout_port(a3)
  end
end
