defmodule CtfServer.VMInventoryTest do
  use ExUnit.Case, async: true

  alias CtfServer.VMInventory

  # classify/3 is pure: attempts only need an `id`, domains/networks are
  # `{name, state}` tuples as VMUtils returns them.
  @cluster_id "05dd9281-4a11-4b8a-be2b-67f7a167c7fc"
  @single_id "9b2f0000-1111-2222-3333-444455556666"
  @ghost_id "434949bb-3622-492a-8abf-bea918199a9e"

  test "groups per-role node domains under their attempt, sorted by role" do
    domains = [
      {"ctf-vm-#{@cluster_id}-web", "running"},
      {"ctf-vm-#{@cluster_id}-poller", "running"},
      {"ctf-vm-#{@cluster_id}-ingress", "shut off"}
    ]

    networks = [{"ctf-#{@cluster_id}", "active"}, {"default", "inactive"}]

    %{clusters: [cluster], orphaned_domains: [], stray_networks: []} =
      VMInventory.classify([%{id: @cluster_id}], domains, networks)

    assert cluster.ghost? == false
    assert cluster.network_state == "active"

    assert [
             %{role: "ingress", state: "shut off"},
             %{role: "poller", state: "running"},
             %{role: "web", state: "running"}
           ] = cluster.nodes
  end

  test "legacy role-less domains show as a single 'vm' node" do
    domains = [{"ctf-vm-#{@single_id}", "running"}]

    %{clusters: [cluster]} = VMInventory.classify([%{id: @single_id}], domains, [])

    assert [%{role: "vm", domain: "ctf-vm-" <> _, state: "running"}] = cluster.nodes
  end

  test "an attempt with no domains is a ghost with a missing network" do
    %{clusters: [cluster]} = VMInventory.classify([%{id: @ghost_id}], [], [])

    assert cluster.ghost?
    assert cluster.nodes == []
    assert cluster.network_state == "missing"
  end

  test "unclaimed domains and ctf networks are orphaned/stray; non-ctf networks are ignored" do
    domains = [{"ctf-vm-#{@ghost_id}-web", "running"}]
    networks = [{"ctf-#{@ghost_id}", "active"}, {"default", "active"}]

    assert %{
             clusters: [],
             orphaned_domains: [{"ctf-vm-" <> _, "running"}],
             stray_networks: [{"ctf-" <> _, "active"}]
           } = VMInventory.classify([], domains, networks)
  end

  test "one attempt's nodes are never claimed by another attempt's prefix" do
    domains = [
      {"ctf-vm-#{@cluster_id}-web", "running"},
      {"ctf-vm-#{@ghost_id}-web", "running"}
    ]

    %{clusters: clusters, orphaned_domains: []} =
      VMInventory.classify([%{id: @cluster_id}, %{id: @ghost_id}], domains, [])

    for cluster <- clusters do
      assert [%{domain: "ctf-vm-" <> rest}] = cluster.nodes
      assert String.starts_with?(rest, cluster.attempt.id)
    end
  end
end
