defmodule CtfServer.VMInventory do
  @moduledoc """
  VM-centric cross-reference of libvirt state with challenge attempts.

  `snapshot/0` gathers the libvirt domains and networks (via
  `CtfUtils.VMUtils`) plus the in-flight VM attempts, and `classify/3`
  (pure — the testable part) buckets them:

    * `:clusters` — one entry per in-flight attempt: its per-role node
      domains, each with its libvirt state, and the state of its isolated
      network. An attempt with no domains at all is a *ghost*
      (crashed/lost provisioning) and gets `ghost?: true`.
    * `:orphaned_domains` — `ctf-vm-*` domains no in-flight attempt claims
      (leaked; `mix ctf.cleanup_vms` reaps them).
    * `:stray_networks` — `ctf-*` attempt networks no in-flight attempt
      claims.
  """

  alias CtfServer.Audit
  alias CtfServer.Challenges

  # Every libvirt call goes through this seam so tests can substitute a stub.
  # Without it the suite would query (and, for the reap paths, mutate) the
  # developer's real `qemu:///system` — the same libvirt the dev server uses.
  defp vm, do: Application.get_env(:ctf_server, :vm_backend, CtfUtils.VMUtils)

  def snapshot do
    classify(
      Challenges.list_vm_attempts_in_flight(),
      vm().list_domains(),
      vm().list_networks()
    )
  end

  @doc """
  Reaps a leaked domain, but only if it is *still* orphaned.

  The check is re-run against a fresh snapshot at call time rather than
  trusting the caller's (possibly stale) page: between rendering the
  inventory and clicking Destroy, a team can have started an attempt that
  claims this very domain. Destroying it then would kill a live player's
  VM, so a domain that is no longer orphaned is refused with
  `{:error, :not_orphaned}`.
  """
  @spec destroy_orphan_domain(String.t(), CtfServer.Accounts.Team.t() | nil) ::
          :ok | {:error, :not_orphaned | :not_a_ctf_domain}
  def destroy_orphan_domain(domain, actor \\ nil) do
    if orphan_domain?(domain) do
      with :ok <- vm().destroy_domain_by_name(domain) do
        Audit.destroy_orphan_domain(domain, actor)
        :ok
      end
    else
      {:error, :not_orphaned}
    end
  end

  @doc """
  Reaps a leaked per-attempt network, re-checking that it is still stray for
  the same reason `destroy_orphan_domain/2` re-checks its domain.
  """
  @spec destroy_stray_network(String.t(), CtfServer.Accounts.Team.t() | nil) ::
          :ok | {:error, :not_stray | :not_a_ctf_network}
  def destroy_stray_network(network, actor \\ nil) do
    if stray_network?(network) do
      with :ok <- vm().destroy_network_by_name(network) do
        Audit.destroy_stray_network(network, actor)
        :ok
      end
    else
      {:error, :not_stray}
    end
  end

  defp orphan_domain?(domain) do
    snapshot().orphaned_domains |> Enum.any?(fn {name, _state} -> name == domain end)
  end

  defp stray_network?(network) do
    snapshot().stray_networks |> Enum.any?(fn {name, _state} -> name == network end)
  end

  @doc """
  Pure classification of `domains`/`networks` (`{name, state}` tuples)
  against `attempts` (anything with an `id`; `snapshot/0` passes
  `%ChallengeAttempt{}`s).
  """
  def classify(attempts, domains, networks) do
    network_state = Map.new(networks)

    clusters =
      Enum.map(attempts, fn attempt ->
        nodes = nodes_for(attempt.id, domains)

        %{
          attempt: attempt,
          nodes: nodes,
          ghost?: nodes == [],
          network_state: Map.get(network_state, "ctf-#{attempt.id}", "missing")
        }
      end)

    claimed_domains =
      for cluster <- clusters, node <- cluster.nodes, into: MapSet.new(), do: node.domain

    claimed_networks = MapSet.new(attempts, &"ctf-#{&1.id}")

    orphaned_domains =
      Enum.reject(domains, fn {name, _state} -> MapSet.member?(claimed_domains, name) end)

    stray_networks =
      networks
      |> Enum.filter(fn {name, _state} -> String.starts_with?(name, "ctf-") end)
      |> Enum.reject(fn {name, _state} -> MapSet.member?(claimed_networks, name) end)

    %{clusters: clusters, orphaned_domains: orphaned_domains, stray_networks: stray_networks}
  end

  # An attempt's node domains share the `ctf-vm-{id}` prefix; the role is
  # whatever follows (`-web`, `-ingress`, ...). A bare `ctf-vm-{id}` (the
  # pre-cluster single-VM naming) renders as role "vm".
  defp nodes_for(attempt_id, domains) do
    prefix = "ctf-vm-#{attempt_id}"

    domains
    |> Enum.flat_map(fn {name, state} ->
      cond do
        name == prefix ->
          [%{role: "vm", domain: name, state: state}]

        String.starts_with?(name, prefix <> "-") ->
          role = String.replace_prefix(name, prefix <> "-", "")
          [%{role: role, domain: name, state: state}]

        true ->
          []
      end
    end)
    |> Enum.sort_by(& &1.role)
  end
end
