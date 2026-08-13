defmodule Mix.Tasks.Ctf.CleanupVms do
  @moduledoc """
  Destroys all CTF-related libvirt domains and networks.

  This is a nuclear option — it kills every `ctf-vm-*` domain and
  `ctf-*` network, regardless of whether they have matching DB records.
  Use `mix ctf.list_vms` first to see what is live.

  Reaping goes through `CtfUtils.VMUtils`, the same path
  `CtfServer.VMInventory` uses, so domains are undefined with the flags a
  post-reboot managed-save state needs and per-attempt overlays are removed
  along with them. A domain that could not be undefined is reported by name
  and the task exits non-zero — a leaked definition must not look like a
  successful cleanup.

  ## Usage

      mix ctf.cleanup_vms
  """

  use Mix.Task

  @shortdoc "Destroy all CTF libvirt domains and networks"

  # Same seam as `CtfServer.VMInventory`, so tests never reap the
  # developer's real `qemu:///system`.
  defp vm, do: Application.get_env(:ctf_server, :vm_backend, CtfUtils.VMUtils)

  @impl Mix.Task
  def run(_args) do
    # VMUtils reaps overlays alongside each domain, which reads
    # `:vm_overlay_path` — so the app config has to be loaded.
    CtfServer.MixHelpers.start_app_insert_only()

    # `list_domains/0` is already limited to `ctf-vm-*`; networks are not.
    domains = Enum.map(vm().list_domains(), fn {name, _state} -> name end)

    networks =
      vm().list_networks()
      |> Enum.map(fn {name, _state} -> name end)
      |> Enum.filter(&String.starts_with?(&1, "ctf-"))

    if domains == [] and networks == [] do
      Mix.shell().info("Nothing to clean up.")
    else
      failures =
        Enum.flat_map(domains, &reap(:domain, &1)) ++
          Enum.flat_map(networks, &reap(:network, &1))

      Mix.shell().info(
        "Cleaned up #{length(domains) - count(failures, :domain)} domain(s) and " <>
          "#{length(networks) - count(failures, :network)} network(s)."
      )

      report_failures(failures)
    end
  end

  # Returns `[]` on success or a single-element failure list, so the caller
  # keeps reaping the rest rather than stopping at the first bad domain.
  defp reap(kind, name) do
    Mix.shell().info("Destroying #{kind} #{name}...")

    result =
      case kind do
        :domain -> vm().destroy_domain_by_name(name)
        :network -> vm().destroy_network_by_name(name)
      end

    case result do
      :ok -> []
      {:error, reason} -> [{kind, name, reason}]
    end
  end

  defp count(failures, kind), do: Enum.count(failures, fn {k, _name, _reason} -> k == kind end)

  defp report_failures([]), do: :ok

  defp report_failures(failures) do
    Mix.shell().error("")
    Mix.shell().error("Failed to destroy #{length(failures)} resource(s):")

    Enum.each(failures, fn {kind, name, reason} ->
      Mix.shell().error("  #{kind} #{name}: #{describe(reason)}")
    end)

    Mix.raise("Cleanup incomplete — #{length(failures)} resource(s) left behind.")
  end

  defp describe({:undefine_failed, output}), do: output
  defp describe(reason), do: inspect(reason)
end
