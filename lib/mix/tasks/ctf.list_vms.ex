defmodule Mix.Tasks.Ctf.ListVms do
  @moduledoc """
  Lists challenge VMs by cross-referencing libvirt state with challenge
  attempts in the database.

  This is the shell-side view of the same inventory `/admin/vms` renders —
  both read `CtfServer.VMInventory.snapshot/0`, so the two agree on what is
  live and what has leaked.

  Shows:
  - Clusters: one entry per in-flight VM attempt, with its per-role node
    domains and the state of its isolated network
  - Ghost attempts: in-flight attempt with no domains at all (crashed/lost
    provisioning)
  - Orphaned domains: `ctf-vm-*` domains no in-flight attempt claims (leaked;
    `mix ctf.cleanup_vms` reaps them)
  - Stray networks: `ctf-*` networks no in-flight attempt claims

  ## Usage

      mix ctf.list_vms
  """

  use Mix.Task

  alias CtfServer.VMInventory

  @shortdoc "Lists active and defunct challenge VMs"

  @impl Mix.Task
  def run(_args) do
    CtfServer.MixHelpers.start_app_insert_only()

    %{clusters: clusters, orphaned_domains: orphaned, stray_networks: strays} =
      VMInventory.snapshot()

    {ghosts, live} = Enum.split_with(clusters, & &1.ghost?)

    section("Clusters (in-flight VM attempts)", live, &print_cluster/1)
    section("Ghost Attempts (no domains)", ghosts, &print_ghost/1)
    section("Orphaned Domains (no matching attempt)", orphaned, &print_named/1)
    section("Stray Networks (no matching attempt)", strays, &print_named/1)

    node_count = live |> Enum.map(&length(&1.nodes)) |> Enum.sum()

    Mix.shell().info("")

    Mix.shell().info(
      "Summary: #{length(live)} cluster(s) / #{node_count} domain(s), " <>
        "#{length(ghosts)} ghost, #{length(orphaned)} orphaned, #{length(strays)} stray network(s)"
    )

    if clusters == [] and orphaned == [] and strays == [] do
      Mix.shell().info("")

      Mix.shell().info(
        "Nothing found. If you expected VMs here, check that libvirtd is " <>
          "running and reachable at qemu:///system."
      )
    end
  end

  defp section(title, entries, printer) do
    Mix.shell().info("")
    Mix.shell().info("=== #{title} ===")

    if entries == [] do
      Mix.shell().info("  (none)")
    else
      Enum.each(entries, printer)
    end
  end

  defp print_cluster(cluster) do
    Mix.shell().info("  " <> attempt_line(cluster.attempt) <> "  net=#{cluster.network_state}")

    Enum.each(cluster.nodes, fn node ->
      Mix.shell().info("      #{node.role}  #{node.domain}  #{node.state}")
    end)
  end

  defp print_ghost(cluster) do
    Mix.shell().info("  " <> attempt_line(cluster.attempt) <> "  net=#{cluster.network_state}")
  end

  defp print_named({name, state}), do: Mix.shell().info("  #{name}  #{state}")

  defp attempt_line(attempt) do
    "#{attempt.id}  port=#{attempt.port || "?"}  " <>
      "group=#{attempt.group}  level=#{attempt.level}  " <>
      "status=#{attempt.status}  team=#{team_label(attempt)}"
  end

  # `list_vm_attempts_in_flight/0` preloads the team, but stay printable if a
  # row's team is somehow missing.
  defp team_label(%{team: %{name: name, id: id}}), do: "#{name} (#{id})"
  defp team_label(%{team_id: team_id}), do: "#{team_id}"
end
