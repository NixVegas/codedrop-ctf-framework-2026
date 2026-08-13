defmodule CtfServer.VMInventoryReapTest do
  @moduledoc """
  The reap guard: `destroy_orphan_domain/2` and `destroy_stray_network/2`
  must refuse anything a live attempt still claims, re-checked against fresh
  libvirt state at call time rather than trusted from the caller's
  (possibly stale) page.

  Libvirt is stubbed (`CtfServer.StubVMBackend`), so these assert the guard
  against a *listed* domain — the dangerous case, where the resource really
  exists and destroying it would kill a live player's VM.
  """
  use CtfServer.DataCase, async: true

  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.Audit
  alias CtfServer.StubVMBackend
  alias CtfServer.VMInventory

  describe "destroy_orphan_domain/2" do
    test "destroys a domain no in-flight attempt claims" do
      StubVMBackend.set_domains([{"ctf-vm-dead-0000-web", "shut off"}])

      assert :ok = VMInventory.destroy_orphan_domain("ctf-vm-dead-0000-web")
      assert StubVMBackend.destroyed() == [{:domain, "ctf-vm-dead-0000-web"}]
    end

    test "refuses a live attempt's domain even though libvirt lists it" do
      attempt = challenge_attempt_fixture(%{status: :started, team_id: team_fixture().id})
      domain = "ctf-vm-#{attempt.id}-web"
      StubVMBackend.set_domains([{domain, "running"}])

      assert {:error, :not_orphaned} = VMInventory.destroy_orphan_domain(domain)
      assert StubVMBackend.destroyed() == []
    end

    test "refuses a domain that vanished from libvirt since the page rendered" do
      StubVMBackend.set_domains([])

      assert {:error, :not_orphaned} = VMInventory.destroy_orphan_domain("ctf-vm-gone-web")
      assert StubVMBackend.destroyed() == []
    end
  end

  describe "destroy_stray_network/2" do
    test "destroys a network no in-flight attempt claims" do
      StubVMBackend.set_networks([{"ctf-dead-0000", "active"}])

      assert :ok = VMInventory.destroy_stray_network("ctf-dead-0000")
      assert StubVMBackend.destroyed() == [{:network, "ctf-dead-0000"}]
    end

    test "refuses a live attempt's network even though libvirt lists it" do
      attempt = challenge_attempt_fixture(%{status: :provisioning, team_id: team_fixture().id})
      network = "ctf-#{attempt.id}"
      StubVMBackend.set_networks([{network, "active"}])

      assert {:error, :not_stray} = VMInventory.destroy_stray_network(network)
      assert StubVMBackend.destroyed() == []
    end

    test "refuses libvirt's own default network" do
      StubVMBackend.set_networks([{"default", "active"}])

      assert {:error, :not_stray} = VMInventory.destroy_stray_network("default")
      assert StubVMBackend.destroyed() == []
    end
  end

  describe "audit wrappers" do
    test "record the resource name and the acting admin" do
      admin = admin_team_fixture()
      StubVMBackend.set_domains([{"ctf-vm-dead-0000-web", "shut off"}])
      StubVMBackend.set_networks([{"ctf-dead-0000", "active"}])

      :ok = VMInventory.destroy_orphan_domain("ctf-vm-dead-0000-web", admin)
      :ok = VMInventory.destroy_stray_network("ctf-dead-0000", admin)

      events = Audit.list_events(topic: "vm").events
      assert length(events) == 2
      assert Enum.all?(events, &(&1.principal_id == admin.id))

      assert %{"domain" => "ctf-vm-dead-0000-web"} =
               Enum.find(events, &(&1.event == "destroy_orphan_domain")).details

      assert %{"network" => "ctf-dead-0000"} =
               Enum.find(events, &(&1.event == "destroy_stray_network")).details
    end
  end
end
