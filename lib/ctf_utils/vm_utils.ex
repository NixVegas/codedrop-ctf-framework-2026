defmodule CtfUtils.VMUtils do
  @moduledoc """
  Helpers for wrangling and managing virtual machines for challenge attempts.

  Uses libvirt/virsh for VM lifecycle management and networking.
  Each challenge attempt gets an isolated private network and one or more VMs.
  """

  require Logger

  # -------------------------------------------------------------------
  # Arch detection
  # -------------------------------------------------------------------

  @doc """
  Host CPU architecture, as far as domain/base-image selection cares.

  Domain arch = host arch = base-image arch, by construction: challenge VMs
  run under KVM on whatever architecture the ctf-server itself runs on.
  """
  @spec host_arch() :: :x86_64 | :aarch64
  def host_arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "aarch64" <> _ -> :aarch64
      "arm64" <> _ -> :aarch64
      _ -> :x86_64
    end
  end

  @doc """
  The `<os>...</os>` block for a libvirt domain, arch-appropriate for the
  current host. On x86_64 this reproduces the original legacy-boot block
  unchanged; on aarch64 it boots UEFI (`virt` machine, `efi` firmware).
  """
  @spec domain_os_xml() :: String.t()
  def domain_os_xml do
    case host_arch() do
      :x86_64 ->
        """
        <os>
          <type arch="x86_64">hvm</type>
          <boot dev="hd"/>
        </os>\
        """

      :aarch64 ->
        """
        <os firmware='efi'>
          <type arch='aarch64' machine='virt'>hvm</type>
          <boot dev='hd'/>
        </os>\
        """
    end
  end

  @doc """
  The `<cpu>` block for a libvirt domain, arch-appropriate for the current
  host. x86_64 has no cpu block today (unchanged); aarch64 KVM has no
  stable named CPU model, so it uses host-passthrough.
  """
  @spec domain_cpu_xml() :: String.t()
  def domain_cpu_xml do
    case host_arch() do
      :x86_64 -> ""
      :aarch64 -> "<cpu mode='host-passthrough'/>"
    end
  end

  # -------------------------------------------------------------------
  # Image building
  # -------------------------------------------------------------------
  #
  # Base qcow2 images are built by Nix directly — see the `vm-bases` flake
  # output and `mix ctf.build_vm_bases`. Nix owns evaluation, caching, and
  # closure dedup; this module only handles per-attempt overlays below.

  # -------------------------------------------------------------------
  # Overlay / image customization
  # -------------------------------------------------------------------

  def base_image_path(filename) do
    :ctf_server
    |> Application.fetch_env!(:vm_base_image_path)
    |> Path.join(filename)
  end

  @doc """
  Per-node overlay path for an attempt.

  Named `{attempt_id}-{role}.qcow2` so every node of an attempt shares a
  common `{attempt_id}-` prefix — `teardown_cluster/1` discovers and reaps
  them by that prefix.
  """
  def overlay_path(attempt_id, role) do
    :ctf_server
    |> Application.fetch_env!(:vm_overlay_path)
    |> Path.join("#{attempt_id}-#{role}.qcow2")
  end

  @doc """
  Creates a qcow2 overlay backed by a base image.

  The overlay is a thin copy-on-write layer — all writes go to the overlay,
  the base image stays untouched.
  """
  @spec create_overlay(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, any()}
  def create_overlay(base_image_path, overlay_path, size \\ nil) do
    # The overlay is created larger than the (small) base image; the guest grows
    # its root fs to fill it at boot (see common/base.nix growPartition +
    # autoResize). qcow2 stays thin, so the extra virtual size only costs host
    # disk as the attempt actually writes. `size` lets a heavy node (e.g. a Hydra
    # store) override the global :vm_overlay_size default.
    size = size || Application.get_env(:ctf_server, :vm_overlay_size, "20G")
    Logger.info("Creating overlay: #{overlay_path} backed by #{base_image_path} (#{size})")

    case System.cmd(
           "qemu-img",
           ["create", "-f", "qcow2", "-b", base_image_path, "-F", "qcow2", overlay_path, size],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("Overlay created: #{overlay_path}")
        {:ok, overlay_path}

      {output, exit_code} ->
        Logger.error("qemu-img create failed (exit #{exit_code}): #{output}")
        {:error, {:overlay_failed, exit_code, output}}
    end
  end

  @doc """
  Injects files into a qcow2 image using guestfish.

  `files` is a list of `{guest_path, content}` tuples.
  """
  @spec inject_files(String.t(), [{String.t(), String.t()}]) :: :ok | {:error, any()}
  def inject_files(image_path, files) do
    file_paths = Enum.map(files, fn {path, _} -> path end)
    Logger.info("Injecting #{length(files)} file(s) into #{image_path}: #{inspect(file_paths)}")

    commands =
      Enum.flat_map(files, fn {guest_path, content} ->
        dir = Path.dirname(guest_path)
        ["mkdir-p #{dir}", "write #{guest_path} \"#{escape_guestfish(content)}\""]
      end)

    guestfish_script =
      Enum.join(["add #{image_path}", "run", "mount /dev/sda1 /" | commands], "\n")

    {:ok, script_path} = Temp.path(suffix: ".gf")
    :ok = File.write(script_path, guestfish_script)

    result =
      case System.cmd("guestfish", ["--file", script_path], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("Guestfish injection complete")
          :ok

        {output, exit_code} ->
          Logger.error("guestfish failed (exit #{exit_code}): #{output}")
          {:error, {:guestfish_failed, exit_code, output}}
      end

    File.rm(script_path)
    result
  end

  defp escape_guestfish(content) do
    content
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  # -------------------------------------------------------------------
  # Networking (libvirt)
  # -------------------------------------------------------------------

  @doc "Deterministic {octet3, octet4} subnet derivation for an attempt."
  @spec subnet_octets(String.t()) :: {150..199, 1..253}
  def subnet_octets(attempt_id) do
    <<b0, b1, _::binary>> = :crypto.hash(:sha256, attempt_id)
    {150 + rem(b0, 50), rem(b1, 253) + 1}
  end

  @doc "Gateway (host) IP on the attempt's isolated bridge."
  @spec gateway_ip(String.t()) :: String.t()
  def gateway_ip(attempt_id) do
    {o3, o4} = subnet_octets(attempt_id)
    "10.#{o3}.#{o4}.1"
  end

  @doc "Network (base) address of the attempt's /24 — the `$SUBNET` nwfilter param."
  @spec subnet_base(String.t()) :: String.t()
  def subnet_base(attempt_id) do
    {o3, o4} = subnet_octets(attempt_id)
    "10.#{o3}.#{o4}.0"
  end

  @doc """
  Static guest IP for node `index` on the attempt's isolated bridge.

  Each node is pinned via a DHCP host reservation (see `network_xml/2`) so the
  host-side DNAT hook — which forwards the ingress node's SSH port to it — has
  a stable target. Node 0 is `.2`, then `.3`, `.4`, …; all sit below the DHCP
  pool (`.10`–`.200`), so at most 8 nodes (indices 0..7) fit before colliding
  with a dynamic lease — plenty for any cluster.
  """
  @spec guest_ip(String.t(), non_neg_integer()) :: String.t()
  def guest_ip(attempt_id, index) when is_integer(index) and index >= 0 and index <= 7 do
    {o3, o4} = subnet_octets(attempt_id)
    "10.#{o3}.#{o4}.#{2 + index}"
  end

  @doc """
  Deterministic per-node MAC for node `index`.

  Uses QEMU's `52:54:00` OUI with the low three octets derived from
  `"{attempt_id}:{index}"` — a distinct input per node, independent of the
  subnet derivation (which hashes the bare `attempt_id`). Each node's DHCP
  host reservation in `network_xml/2` keys off this.
  """
  @spec guest_mac(String.t(), non_neg_integer()) :: String.t()
  def guest_mac(attempt_id, index) when is_integer(index) and index >= 0 do
    <<a, b, c, _::binary>> = :crypto.hash(:sha256, "#{attempt_id}:#{index}")

    suffix =
      Enum.map_join([a, b, c], ":", fn byte ->
        byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
      end)

    "52:54:00:" <> suffix
  end

  @doc """
  libvirt network definition for an attempt (NAT-forwarded, host-routed egress).

  `node_count` pins one DHCP host reservation per node (`guest_mac/2` →
  `guest_ip/2` for indices `0..node_count-1`).
  """
  @spec network_xml(String.t(), pos_integer()) :: String.t()
  def network_xml(attempt_id, node_count) when is_integer(node_count) and node_count >= 1 do
    {o3, o4} = subnet_octets(attempt_id)

    reservations =
      Enum.map_join(0..(node_count - 1), "\n", fn index ->
        ~s(        <host mac="#{guest_mac(attempt_id, index)}" ip="#{guest_ip(attempt_id, index)}"/>)
      end)

    """
    <network>
      <name>#{network_name(attempt_id)}</name>
      #{forward_element()}
      <bridge name="ctf-#{String.slice(attempt_id, 0..7)}"/>
      <ip address="10.#{o3}.#{o4}.1" netmask="255.255.255.0">
        <dhcp>
          <range start="10.#{o3}.#{o4}.10" end="10.#{o3}.#{o4}.200"/>
    #{reservations}
        </dhcp>
      </ip>
    </network>
    """
  end

  # The `<forward>` element for the attempt network. libvirt masquerades the
  # attempt's /24 out to the world; when `:vm_egress_interface` is configured we
  # pin the NAT to that host interface (`dev=`) so all VM egress leaves via the
  # CTF uplink (the one carrying the box's default route) rather than whatever
  # interface libvirt would otherwise pick. Unset (dev/test) keeps the plain
  # `mode='nat'` form so libvirt follows the host default route unpinned.
  defp forward_element do
    case Application.get_env(:ctf_server, :vm_egress_interface) do
      iface when is_binary(iface) and iface != "" ->
        "<forward mode='nat' dev='#{iface}'/>"

      _ ->
        "<forward mode='nat'/>"
    end
  end

  @doc """
  Creates an isolated libvirt network for a challenge attempt, with
  `node_count` pinned DHCP reservations (one per cluster node).

  The network is NAT-forwarded so VMs reach the outside world through a
  host-routed egress path that later tasks can filter. SSH access is provided
  via port forwarding on the ingress domain.

  Returns `{:ok, network_name}` or `{:error, reason}`.
  """
  @spec create_network(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  def create_network(attempt_id, node_count) do
    network_name = network_name(attempt_id)
    {o3, o4} = subnet_octets(attempt_id)

    Logger.info(
      "Creating network #{network_name} (10.#{o3}.#{o4}.0/24, NAT, #{node_count} node(s))"
    )

    xml = network_xml(attempt_id, node_count)

    with {:ok, xml_path} <- write_temp_xml(xml),
         {_, 0} <- virsh(["net-define", xml_path]),
         {_, 0} <- virsh(["net-start", network_name]),
         {_, 0} <- virsh(["net-autostart", network_name]) do
      File.rm(xml_path)
      Logger.info("Network #{network_name} started")
      {:ok, network_name}
    else
      {output, exit_code} ->
        Logger.error("Network creation failed (exit #{exit_code}): #{output}")
        {:error, {:network_failed, exit_code, output}}
    end
  end

  @doc """
  Destroys a libvirt network for a challenge attempt.
  """
  @spec destroy_network(String.t()) :: :ok | {:error, any()}
  def destroy_network(attempt_id) do
    network_name = network_name(attempt_id)
    Logger.info("Destroying network #{network_name}")

    virsh(["net-destroy", network_name])
    virsh(["net-undefine", network_name])
    :ok
  end

  defp network_name(attempt_id), do: "ctf-#{attempt_id}"

  # -------------------------------------------------------------------
  # VM lifecycle (libvirt)
  # -------------------------------------------------------------------

  @doc """
  Defines and starts a VM via libvirt from a domain XML string.

  The XML should be a complete libvirt domain definition. Use
  `domain_name/1` to generate a consistent name for the domain.

  Returns `{:ok, domain_name}` or `{:error, reason}`.
  """
  @spec start_vm(String.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  def start_vm(domain_name, xml) do
    Logger.info("Starting VM #{domain_name}")

    with {:ok, xml_path} <- write_temp_xml(xml),
         {_, 0} <- virsh(["define", xml_path]),
         {_, 0} <- virsh(["start", domain_name]),
         {_, 0} <- virsh(["autostart", domain_name]) do
      File.rm(xml_path)
      Logger.info("VM #{domain_name} started")
      {:ok, domain_name}
    else
      {output, exit_code} ->
        Logger.error("VM start failed (exit #{exit_code}): #{output}")
        {:error, {:vm_start_failed, exit_code, output}}
    end
  end

  @doc """
  Per-node domain name for an attempt: `ctf-vm-{attempt_id}-{role}`.

  Shares the `ctf-vm-{attempt_id}-` prefix across an attempt's nodes so
  `teardown_cluster/1` can discover them.
  """
  def domain_name(attempt_id, role), do: "ctf-vm-#{attempt_id}-#{role}"

  # -------------------------------------------------------------------
  # Cluster orchestration
  # -------------------------------------------------------------------
  #
  # An attempt is a *cluster* of VMs on one isolated network, with exactly one
  # ingress node (the SSH target). Most challenges are a cluster of one; the
  # single-VM case is just `start_cluster/3` with a one-element node list.

  @typedoc """
  One node of a challenge cluster.

  * `:role` — short label; names the domain/overlay (`ctf-vm-{id}-{role}`) and
    picks the per-node IP/MAC index by list position.
  * `:base_image` — base qcow2 filename under `vm_base_image_path`.
  * `:domain_template` — path to *this challenge's own* `domain.xml.eex`.
  * `:files` — `{guest_path, content}` tuples injected via guestfish.
  * `:ingress?` — the SSH target: gets `ssh_port`/the DNAT hook; peers get neither.
  * `:extra_assigns` — optional extra bindings merged into the domain render.
  * `:overlay_size` — optional per-node qcow2 overlay virtual size (a `qemu-img`
    size string, e.g. `"64G"`); overrides the global `:vm_overlay_size` for a node
    with an unusually large working set (e.g. a Hydra store pulling a bootstrap).
  """
  @type node_spec :: %{
          :role => String.t(),
          :base_image => String.t(),
          :domain_template => String.t(),
          optional(:files) => [{String.t(), String.t()}],
          optional(:ingress?) => boolean(),
          optional(:extra_assigns) => keyword(),
          optional(:overlay_size) => String.t()
        }

  @doc """
  Stands up a cluster of VMs for an attempt: one isolated network with a pinned
  DHCP reservation per node, then each node's overlay → file injection → domain.

  Options:
  * `:hub_mode` (default `false`) — mark every node's domain so the (root)
    libvirt qemu hook disables MAC learning on its bridge port, flooding
    unknown-unicast to every port so a promiscuous node can capture peer↔peer
    traffic. Leave off for normal (switched) clusters. The unprivileged service
    only emits the marker; the hook does the privileged bridge op.

  On any failure, everything created so far is torn down via
  `teardown_cluster/1` before returning `{:error, reason}`.
  """
  @spec start_cluster(CtfServer.ChallengeAttempt.t(), [node_spec()], keyword()) ::
          :ok | {:error, any()}
  def start_cluster(attempt, node_specs, opts \\ []) when is_list(node_specs) do
    hub_mode? = Keyword.get(opts, :hub_mode, false)

    case preflight_networking() do
      :ok ->
        with {:ok, _net} <- create_network(attempt.id, length(node_specs)),
             :ok <- start_nodes(attempt, node_specs, hub_mode?) do
          :ok
        else
          {:error, reason} ->
            teardown_cluster(attempt)
            {:error, reason}
        end

      {:error, _reason} = error ->
        # Nothing created yet — no teardown needed.
        error
    end
  end

  # Fail fast with an actionable message if the challenge-VM libvirt networking
  # isn't set up (the ctf-egress nwfilter is missing, or libvirtd is
  # unreachable). Otherwise the first domain start dies deep in libvirt with a
  # cryptic "Cannot find filter 'ctf-egress'". In production the ctf-server
  # module manages this; in dev, import the ctf-dev module (see HACKING.md).
  defp preflight_networking do
    case virsh(["nwfilter-list"]) do
      {output, 0} ->
        if String.contains?(output, "ctf-egress") do
          :ok
        else
          Logger.error(networking_hint())
          {:error, :networking_not_ready}
        end

      {output, _code} ->
        Logger.error("libvirtd not reachable (#{String.trim(output)}). " <> networking_hint())
        {:error, :networking_not_ready}
    end
  end

  defp networking_hint do
    "Challenge-VM networking is not set up (the ctf-egress libvirt nwfilter is " <>
      "missing). In dev, import the ctf-dev NixOS module and rebuild (see " <>
      "HACKING.md -> \"Running challenges locally\"); in production the ctf-server " <>
      "module manages this."
  end

  @doc """
  Tears down every resource an attempt's cluster holds.

  Discovers domains by the shared `ctf-vm-{id}-` prefix (so it reaps partial
  or unknown-shape clusters), removes each node's overlay by the `{id}-`
  prefix, then destroys the network. Idempotent.
  """
  @spec teardown_cluster(CtfServer.ChallengeAttempt.t()) :: :ok
  def teardown_cluster(attempt) do
    attempt_id = attempt.id

    for domain <- discover_domains(attempt_id) do
      virsh(["destroy", domain])
      # Failure is logged by undefine_domain/1 rather than raised: teardown
      # must keep going and reap the remaining nodes, overlays, and network.
      _ = undefine_domain(domain)
    end

    overlay_dir = Application.fetch_env!(:ctf_server, :vm_overlay_path)

    overlay_dir
    |> Path.join("#{attempt_id}-*.qcow2")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)

    destroy_network(attempt_id)
    :ok
  end

  # Reduce over the nodes, short-circuiting on the first failure so the caller
  # can roll the whole cluster back.
  defp start_nodes(attempt, node_specs, hub_mode?) do
    node_specs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {spec, index}, :ok ->
      case start_one_node(attempt, spec, index, hub_mode?) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_one_node(attempt, spec, index, hub_mode?) do
    role = spec.role
    overlay = overlay_path(attempt.id, role)
    File.mkdir_p!(Path.dirname(overlay))

    domain_xml =
      EEx.eval_file(spec.domain_template, domain_assigns(attempt, spec, index, hub_mode?))

    with {:ok, _} <-
           create_overlay(base_image_path(spec.base_image), overlay, Map.get(spec, :overlay_size)),
         :ok <- inject_files(overlay, Map.get(spec, :files, [])),
         {:ok, _} <- start_vm(domain_name(attempt.id, role), domain_xml) do
      :ok
    end
  end

  # The standard per-node bindings every challenge domain template expects.
  # Centralizes what each challenge used to hand-assemble inline. An ingress
  # node gets the attempt's forwarded SSH port (and hence the DNAT hook); peers
  # get `nil`, and the template omits the hook. `hub_mode` marks the domain for
  # the qemu hook's bridge learning-off (see `start_cluster/3`).
  defp domain_assigns(attempt, spec, index, hub_mode?) do
    ingress? = Map.get(spec, :ingress?, false)

    [
      domain_name: domain_name(attempt.id, spec.role),
      image_path: overlay_path(attempt.id, spec.role),
      network_name: network_name(attempt.id),
      ssh_port: if(ingress?, do: attempt.port, else: nil),
      guest_mac: guest_mac(attempt.id, index),
      guest_ip: guest_ip(attempt.id, index),
      gateway_ip: gateway_ip(attempt.id),
      subnet: subnet_base(attempt.id),
      hub_mode: hub_mode?,
      os_block: domain_os_xml(),
      cpu_block: domain_cpu_xml()
    ] ++ Map.get(spec, :extra_assigns, [])
  end

  defp discover_domains(attempt_id) do
    case virsh(["list", "--all", "--name"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "ctf-vm-#{attempt_id}-"))

      _ ->
        []
    end
  end

  @doc """
  Resumes a paused attempt: reactivate its network, then start every node domain.

  Node domains are discovered by the shared `ctf-vm-{id}-` prefix (like
  `teardown_cluster/1`), so single- and multi-node attempts both resume whole.
  Unlike `start_vm/2` this does not (re)define anything: definitions and
  overlays persist across a pause, so guests come back with disk state intact.
  An already-running domain is treated as success, so a resume that races a
  slow pause is idempotent.
  """
  @spec start_domain(String.t()) :: :ok | {:error, any()}
  def start_domain(attempt_id) do
    # A domain can't start unless its network is active. A persistent
    # per-attempt network can be left inactive by a libvirtd restart (e.g.
    # across a redeploy) if it wasn't set to autostart, so ensure it's up
    # before starting the guests.
    with :ok <- start_network(attempt_id) do
      attempt_id
      |> discover_domains()
      |> Enum.reduce_while(:ok, fn domain, :ok ->
        case do_start_domain(domain) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp do_start_domain(domain) do
    Logger.info("Starting domain #{domain}")

    case virsh(["start", domain]) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        if String.contains?(output, "already active") do
          :ok
        else
          Logger.error("Domain start failed (exit #{exit_code}): #{output}")
          {:error, {:domain_start_failed, exit_code, output}}
        end
    end
  end

  @doc """
  Ensures an attempt's network is active, re-arming its autostart.

  Used when resuming. A persistent per-attempt network can be left inactive by
  a libvirtd restart if it isn't set to autostart; `net-start` reactivates it
  (an already-active network is treated as success). If the network is gone
  entirely (undefined out of band), it is recreated from the deterministic spec
  — same subnet, bridge, and DHCP reservations — so the still-defined node
  domains reconnect. Autostart is re-armed so a later host reboot brings it
  back automatically.
  """
  @spec start_network(String.t()) :: :ok | {:error, any()}
  def start_network(attempt_id) do
    network_name = network_name(attempt_id)

    case virsh(["net-start", network_name]) do
      {_, 0} ->
        virsh(["net-autostart", network_name])
        :ok

      {output, exit_code} ->
        cond do
          String.contains?(output, "already active") ->
            virsh(["net-autostart", network_name])
            :ok

          network_missing?(output) ->
            recreate_network(attempt_id)

          true ->
            Logger.error("Network start failed (exit #{exit_code}): #{output}")
            {:error, {:network_start_failed, exit_code, output}}
        end
    end
  end

  defp network_missing?(output) do
    String.contains?(output, "no network with matching name") or
      String.contains?(output, "failed to get network")
  end

  # The persistent per-attempt network was gone, so recreate it. The node count
  # comes from the still-defined domains (discovered by prefix), so a multi-node
  # cluster gets all of its DHCP reservations back; `create_network/2` handles
  # net-define + net-start + net-autostart.
  defp recreate_network(attempt_id) do
    node_count = max(length(discover_domains(attempt_id)), 1)

    Logger.warning(
      "Network for attempt #{attempt_id} not found; recreating with #{node_count} node(s)"
    )

    case create_network(attempt_id, node_count) do
      {:ok, _network_name} -> :ok
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Pauses an attempt: power off every node domain, keeping definitions/overlays.

  Each guest powers off (freeing host CPU/RAM) but its definition and overlay
  persist, so `start_domain/1` brings the whole cluster back. Domains are
  discovered by the shared `ctf-vm-{id}-` prefix. Errors (e.g. a domain already
  stopped) are logged by virsh and ignored.
  """
  @spec stop_domain(String.t()) :: :ok
  def stop_domain(attempt_id) do
    for domain <- discover_domains(attempt_id) do
      Logger.info("Stopping (pausing) domain #{domain}")
      virsh(["destroy", domain])
    end

    :ok
  end

  @doc """
  Enables or disables libvirt autostart for every node domain of an attempt.

  Autostart is on while an attempt is running (so it survives a host reboot)
  and off once paused (so a paused attempt stays down until resumed). Domains
  are discovered by the shared `ctf-vm-{id}-` prefix.
  """
  @spec set_domain_autostart(String.t(), boolean()) :: :ok
  def set_domain_autostart(attempt_id, enabled?) do
    flag = if enabled?, do: [], else: ["--disable"]

    for domain <- discover_domains(attempt_id) do
      virsh(["autostart"] ++ flag ++ [domain])
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Inventory
  # -------------------------------------------------------------------

  @doc """
  Lists every challenge-VM libvirt domain (`ctf-vm-*`) as `{name, state}`.

  One `virsh list --all` call; the state is the table column verbatim
  (`"running"`, `"shut off"`, ...). Returns `[]` if libvirtd is unreachable.
  """
  @spec list_domains() :: [{String.t(), String.t()}]
  def list_domains do
    case virsh(["list", "--all"]) do
      {output, 0} ->
        # Table rows are `Id  Name  State`; domain names never contain
        # whitespace, states may ("shut off").
        parse_virsh_table(output, ~r/^\s*\S+\s+(\S+)\s+(.+?)\s*$/)
        |> Enum.filter(fn {name, _} -> String.starts_with?(name, "ctf-vm-") end)

      _ ->
        []
    end
  end

  @doc """
  Lists every libvirt network as `{name, state}` (`"active"`/`"inactive"`).

  Returns `[]` if libvirtd is unreachable.
  """
  @spec list_networks() :: [{String.t(), String.t()}]
  def list_networks do
    case virsh(["net-list", "--all"]) do
      {output, 0} -> parse_virsh_table(output, ~r/^\s*(\S+)\s+(\S+)/)
      _ -> []
    end
  end

  # Drops the `Header ---` preamble of a virsh table and maps each row
  # through a two-capture regex into a `{name, state}` tuple.
  defp parse_virsh_table(output, row_regex) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(String.trim_leading(&1), "---")))
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case Regex.run(row_regex, line) do
        [_, name, state] -> [{name, state}]
        _ -> []
      end
    end)
  end

  @doc """
  Destroys and undefines a single libvirt domain by name, then removes any
  per-attempt overlays whose name it implies.

  Used to reap a *leaked* domain — one no attempt claims any more, so there
  is no attempt record to drive `teardown_cluster/1`. Callers must confirm
  the domain is genuinely unclaimed first (see `CtfServer.VMInventory`).
  Idempotent: a domain that is already gone (or was never running) is
  success, matching `teardown_cluster/1`.
  """
  @spec destroy_domain_by_name(String.t()) ::
          :ok | {:error, :not_a_ctf_domain | {:undefine_failed, String.t()}}
  def destroy_domain_by_name("ctf-vm-" <> rest = domain) do
    virsh(["destroy", domain])

    with :ok <- undefine_domain(domain) do
      # `rest` is "{attempt_id}" or "{attempt_id}-{role}"; the overlay is named
      # "{attempt_id}-{role}.qcow2", so reap by the attempt-id prefix.
      attempt_id = rest |> String.split("-") |> Enum.take(5) |> Enum.join("-")

      :ctf_server
      |> Application.fetch_env!(:vm_overlay_path)
      |> Path.join("#{attempt_id}-*.qcow2")
      |> Path.wildcard()
      |> Enum.each(&File.rm/1)

      :ok
    end
  end

  def destroy_domain_by_name(_other), do: {:error, :not_a_ctf_domain}

  # Undefining needs every piece of per-domain state named explicitly, or
  # libvirt refuses and the definition leaks:
  #
  #   * `--managed-save` — `libvirt-guests` managed-saves running guests when
  #     the host shuts down, so after any host reboot every challenge domain
  #     has a save image and a plain `undefine` fails with "Refusing to
  #     undefine while domain managed save image exists".
  #   * `--nvram` — aarch64 hosts boot the domains UEFI, which keeps a
  #     varstore. A no-op on the x86_64 legacy-boot domains.
  #
  # An already-absent domain is success, so teardown stays idempotent.
  defp undefine_domain(domain) do
    case virsh(["undefine", "--managed-save", "--nvram", domain]) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        if domain_missing?(output) do
          :ok
        else
          Logger.error("Undefining #{domain} failed: #{String.trim(output)}")
          {:error, {:undefine_failed, String.trim(output)}}
        end
    end
  end

  defp domain_missing?(output) do
    String.contains?(output, "failed to get domain") or
      String.contains?(output, "Domain not found")
  end

  @doc """
  Destroys and undefines a single libvirt network by name.

  Like `destroy_domain_by_name/1`, this is for reaping a leaked per-attempt
  network; only `ctf-` prefixed networks are eligible, so libvirt's own
  `default` network can never be destroyed through here.
  """
  @spec destroy_network_by_name(String.t()) :: :ok | {:error, :not_a_ctf_network}
  def destroy_network_by_name("ctf-" <> _ = network) do
    virsh(["net-destroy", network])
    virsh(["net-undefine", network])
    :ok
  end

  def destroy_network_by_name(_other), do: {:error, :not_a_ctf_network}

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp virsh(args) do
    uri = Application.fetch_env!(:ctf_server, :vm_libvirt_uri)
    System.cmd("virsh", ["-c", uri | args], stderr_to_stdout: true)
  end

  defp write_temp_xml(xml) do
    {:ok, path} = Temp.path(suffix: ".xml")
    :ok = File.write(path, xml)
    {:ok, path}
  end
end
