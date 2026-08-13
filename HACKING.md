# Hacking on ctf-server

## Dev environment

This project uses a Nix flake for development. Enter the dev shell:

```sh
nix develop
```

This gives you Elixir, Erlang, PostgreSQL, Node, and VM tooling (QEMU, libguestfs, libvirt).

PostgreSQL is started automatically in the dev shell. Run `mix setup` to create the database and install dependencies.

### Host requirements

Libvirt must be running in system mode for VM networking (bridges). On NixOS:

```nix
virtualisation.libvirtd.enable = true;
users.users.<you>.extraGroups = [ "libvirtd" ];
```

All `virsh` calls use `-c qemu:///system`.

## Mix tasks

| Task | Description |
|------|-------------|
| `mix ctf.build_vm_bases` | Builds standalone qcow2 base images for all challenges that define a `vm_base_config/0` |
| `mix ctf.test_vm <group> <level>` | Boots a challenge VM for manual testing with a throwaway SSH key |
| `mix ctf.list_vms` | Cross-references libvirt domains with DB attempts to show active, orphaned, and ghost VMs |
| `mix ctf.cleanup_vms` | Destroys all `ctf-*` libvirt domains and networks |

## Challenge architecture

Each challenge implements the `CtfServer.ChallengeBehavior` behaviour and the `CtfServer.Challenge` protocol. Challenge files live under `lib/ctf_server/challenges/` with supporting VM configs and templates under `priv/challenges/<name>/`.

### Key callbacks

| Callback | Purpose |
|----------|---------|
| `name/0`, `group/0`, `level/0`, `max_score/0` | Metadata |
| `vm_base_config/0` (optional) | Returns the Nix expression for the base VM image |
| `create_flag/2` | Generates a team-specific flag |
| `instantiate_challenge_attempt/3` | Sets up VMs, injects flag/pubkey, starts the challenge |
| `cleanup_challenge_attempt/2` | Tears down VMs, networks, overlay |
| `score_challenge_attempt/3` | Validates a submitted flag |

### Challenge attempt lifecycle

```
nil -> :provisioning -> :started -> :deprovisioning -> :completed
```

- **nil** — team hasn't started the challenge
- **provisioning** — Oban worker is building overlay, injecting files, starting VMs
- **started** — VM is running, team can SSH in and work
- **deprovisioning** — team submitted flag, VMs being torn down
- **completed** — done, score recorded

Ports are allocated from the configured `vm_port_range` via `CtfServer.PortManager` (DB-backed with advisory locks). Ports are implicitly freed when an attempt reaches `:completed`.

## Challenge VM development

Each challenge can define a NixOS VM configuration and a libvirt domain template. Files live under `priv/challenges/<challenge_name>/`:

```
priv/challenges/basic_nix_1/
  vm.nix              # NixOS config for the base image
  domain.xml.eex      # Libvirt domain XML template
```

### Testing a VM config standalone

Build the base image without the app:

```sh
mix ctf.build_vm_bases
```

Boot it for manual testing (generates a throwaway SSH key, creates a CoW overlay):

```sh
mix ctf.test_vm basic-nix 1
# SSH command is printed to the console
```

Or boot directly with QEMU:

```sh
qemu-system-x86_64 \
  -drive file=priv/vm_bases/basic-nix_1.qcow2,format=qcow2,if=virtio \
  -m 1024 -nographic \
  -net nic -net user,hostfwd=tcp::2222-:22
```

### VM lifecycle

The provisioning pipeline for a challenge attempt:

1. **Pre-build** (`mix ctf.build_vm_bases`) — builds standalone qcow2 images with baked-in Nix stores. No host store sharing.
2. **Per-attempt overlay** — creates a CoW qcow2 overlay on the base image so team activity doesn't touch the base.
3. **Customization** — injects SSH pubkey and challenge seed into the overlay via guestfish.
4. **Launch** — renders the challenge's `domain.xml.eex` template, defines a libvirt domain and isolated network, starts the VM with SSH port-forwarded to the allocated host port.
5. **Teardown** — `virsh destroy`/`undefine`, network cleanup, overlay deletion.

### Adding a new challenge

Everything for a challenge lives in two places: the module at
`lib/ctf_server/challenges/YourChallenge.ex` and its assets under
`priv/challenges/<group>_<level>/`. **Provisioning goes through one API —
`CtfUtils.VMUtils.start_cluster/3` and `teardown_cluster/1` — whether the
challenge is a single VM or a cluster; a single-VM challenge is just a cluster
of one.** See `BasicNix1` for a single-VM example and `CaptureThePoll` for a
cluster.

1. **Challenge module** — the `CtfServer.ChallengeBehavior` metadata callbacks
   plus the `CtfServer.Challenge` protocol:
   ```elixir
   defmodule CtfServer.Challenges.YourChallenge do
     @behaviour CtfServer.ChallengeBehavior
     defstruct []

     def group, do: "your-group"
     def level, do: 1
     def max_score, do: 100
     def name, do: "Your Challenge Name"

     # nil for a no-VM challenge (see Challenges.needs_vm?/1); otherwise the
     # base vm.nix contents — its non-nil-ness is the "needs a VM" signal.
     def vm_base_config do
       :ctf_server |> :code.priv_dir()
       |> Path.join("challenges/your_group_1/vm.nix") |> File.read!()
     end

     def description, do: "..."

     defimpl CtfServer.Challenge do
       # name/description/group/level/max_score delegate to @for.*
       # create_flag/2, instantiate_challenge_attempt/3,
       # cleanup_challenge_attempt/2, score_challenge_attempt/3 — below.
     end
   end
   ```

2. **`instantiate_challenge_attempt/3`** — do any per-team precompute (render a
   `.nix.eex`, generate a seed), then declare the node(s) and call
   `start_cluster`:
   ```elixir
   def instantiate_challenge_attempt(challenge, attempt, pubkey) do
     VMUtils.start_cluster(attempt, [
       %{
         role: "main",
         ingress?: true,
         base_image: "your-group_1.qcow2",
         domain_template: priv("your_group_1/domain.xml.eex"),
         files:
           [{"/home/ctf/.ssh/authorized_keys", pubkey}, {"/home/ctf/flag.txt", flag}]
           ++ CtfServer.ChallengeBanner.login_files(challenge)
       }
     ])
   end
   ```
   `start_cluster` creates the per-attempt network, and per node: the overlay,
   the `files` injection (guestfish), rendering the node's `domain_template`
   with the standard bindings, and starting the domain — rolling the whole
   cluster back on any failure. The standard template bindings are:
   `domain_name`, `image_path`, `network_name`, `ssh_port`, `guest_ip`,
   `guest_mac`, `gateway_ip`, `subnet`, `hub_mode`, `os_block`, `cpu_block`.
   The `ingress?: true` node gets the forwarded SSH port + DNAT hook; others
   get `nil` and no forward.

3. **`cleanup_challenge_attempt/2`** — just `VMUtils.teardown_cluster(attempt)`.
   It discovers the attempt's domains by the `ctf-vm-{id}-` prefix, so it reaps
   single- and multi-node attempts alike.

4. **`create_flag/2`** returns the team-specific flag (wrapped as `Nix{...}` for
   display); **`score_challenge_attempt/3`** receives the unwrapped submission
   and compares it to the expected flag.

5. **VM config + domain template** at `priv/challenges/<group>_<level>/`:
   - `vm.nix` — `imports = [ ../common/base.nix ];` plus only what's specific
     (the base handles qemu-guest profile, serial console, SSH, the `ctf` user).
     Don't use `virtualisation.*` options (those are for NixOS test VMs).
     If the team builds a derivation inside the VM, the challenge network is
     offline — pin `<nixpkgs>` and pre-seed the closure (see `basic_nix_4/vm.nix`).
   - `domain.xml.eex` — copy `basic_nix_1/domain.xml.eex`; it consumes the
     standard bindings above.

6. **Build and test**:
   ```sh
   mix ctf.build_vm_bases
   mix ctf.test_vm your-group 1
   ```

#### Multi-node (cluster) challenges

A challenge becomes a *cluster* when its dir ships a `nodes/` subdir instead of
being one image. Each `nodes/<role>.nix` imports the challenge's own `vm.nix`
base and is baked into its own image (`<group>_<level>_<role>.qcow2`); the
top-level `vm.nix` is a base module only, never built directly. `CaptureThePoll`
(`priv/challenges/capture_the_poll_1/`) is the worked example.

- **Declare one spec per node** in `instantiate`, exactly one with
  `ingress?: true` (the SSH target). Peers reach each other, and the ingress,
  over the attempt's private `/24`.
- **Per-node egress** is chosen by each node's `domain_template` `<filterref>`.
  Every egress filter drops the `internalZones` fleet denylist (all RFC1918 by
  default: other VM subnets, the arena fabric, overlays), so NO filter egresses
  cross-zone. What differs is the local exemption and the tail:
  - `ctf-egress` is the **default** every VM uses. `clusterLocal = false`, so it
    exempts the gateway + its DNS (`$GATEWAY`). Allow-all by default (reaches
    `allowSubnets` + the public internet, but not the fleet); lock down in prod
    (`services.ctf-libvirt.egressFilters.ctf-egress.allowAll = false`) so it
    reaches only the gateway + `allowSubnets` (the cache).
  - `ctf-egress-internet` is the filter the internet-needing erinyes challenges
    use. `clusterLocal = true` (exempts the whole own `/24` via `$SUBNET`, so
    cluster siblings stay reachable) and allow-all (reaches `allowSubnets` + the
    internet). Prod can keep it open while locking down `ctf-egress`.
  - `ctf-cluster-internal` is siblings-only (`/24` + ARP/DHCP), no gateway/net; a
    separate (non-egress) isolation filter for peers that must not talk outward.

  A `clusterLocal = false` filter's templates pass `$GATEWAY`; a `clusterLocal =
  true` (or `ctf-cluster-internal`) filter's templates pass `$SUBNET`, both from
  the `subnet`/`gateway_ip` bindings. Keep an ingress on a filter that exempts
  the gateway (either does) for the SSH return path.
- **`hub_mode`** — pass `start_cluster(attempt, nodes, hub_mode: true)` to have
  the **root qemu hook** disable MAC learning on each node's bridge port, so a
  promiscuous node can capture peer↔peer traffic. The unprivileged service only
  stamps a `hub-mode` marker into the domain metadata; the hook does the bridge op.

Validate a cluster challenge with a NixOS VM test — see
`nixos/tests/ctf-server-capture-the-poll.nix`.

> `priv(...)` above is shorthand for
> `:ctf_server |> :code.priv_dir() |> Path.join("challenges/" <> ...)`.

#### Running challenges locally

Dev uses the **same libvirt networking as production** — the real per-attempt
bridge plus the root qemu hook (SSH DNAT + hub-mode). There is no SLiRP
fallback; single-VM and cluster challenges take one path. So a dev machine
needs that networking set up once:

1. Add the dev module to your machine's NixOS config and `nixos-rebuild switch`:
   ```nix
   imports = [ inputs.ctf-server.nixosModules.ctf-dev ];
   users.users.<you>.extraGroups = [ "libvirtd" ];
   ```
   (equivalently: import `nixosModules.ctf-libvirt` and set
   `services.ctf-libvirt.enable = true`.)
2. `mix phx.server` — challenge VMs now come up on the real bridge, reachable
   at `ssh -p <port> localhost` (the hook DNATs host-local connections too).
   Cluster challenges and hub-mode capture work here just like in production.

Without that module a VM challenge can't provision (its domain references the
`ctf-egress` nwfilter, which the module defines). To poke a full cluster
without touching your machine config, drive the NixOS test interactively:
```sh
nix run .#checks.x86_64-linux.ctf-server-capture-the-poll.driverInteractive
```

### Debugging VMs

```sh
mix ctf.list_vms                                  # what's running, leaked, or lost
mix ctf.cleanup_vms                               # nuke everything
virsh -c qemu:///system list --all                # all libvirt domains
virsh -c qemu:///system console ctf-vm-<id>       # serial console into a VM
virsh -c qemu:///system net-list --all            # all libvirt networks
```

## Configuration

Key app config values in `config/config.exs`:

| Key | Default | Description |
|-----|---------|-------------|
| `vm_port_range` | `1024..1048` | Port range for SSH forwarding to VMs |
| `vm_base_image_path` | `priv/vm_bases/` | Where built base images are stored |
| `vm_ssh_host` | `localhost` | Hostname shown in SSH commands to teams |
