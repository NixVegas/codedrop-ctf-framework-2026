# Libvirt networking for CTF challenge VMs, split out so both the production
# `services.ctf-server` module and a developer's machine use the same path:
# the per-attempt SSH-forward + hub-mode qemu hook, the egress nwfilters, the
# iptables firewall-backend pin, and the VM SSH port-range firewall opening.
#
# On a dev box, enabling this (see the flake's nixosModules.ctf-dev) lets
# challenge VMs run over the real bridge + DNAT hook under `mix phx.server`, so
# single-VM and cluster challenges (with hub-mode capture) work locally, the
# same path as production.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    types
    optional
    ;
  cfg = config.services.ctf-libvirt;

  # libvirt qemu hook: forwards each attempt VM's SSH port into its isolated
  # NAT vnet, and flips cluster taps into hub mode. On domain `start` it DNATs
  # the host port (embedded in the domain's <metadata>) to the guest's pinned
  # IP:22; on `started` it applies hub mode; on `stopped` it removes the DNAT.
  qemuHook = pkgs.writeShellScript "ctf-qemu-hook" ''
    set -euo pipefail

    guest="''${1:-}"
    op="''${2:-}"

    # Only act on our challenge VMs.
    case "$guest" in
      ctf-vm-*) ;;
      *) exit 0 ;;
    esac

    # libvirt feeds the full domain XML on stdin.
    xml="$(cat)"

    attr() {
      printf '%s' "$xml" \
        | ${pkgs.libxml2}/bin/xmllint --xpath "string(//*[local-name()='hook']/@$1)" - 2>/dev/null || true
    }

    port="$(attr ssh-port)"
    gip="$(attr guest-ip)"
    hub="$(attr hub-mode)"

    # No metadata we recognise (a non-CTF domain that happens to match, or a
    # challenge wanting neither the SSH forward nor hub mode) -> nothing to do.
    [ -n "$port" ] || [ "$hub" = "on" ] || exit 0

    ipt="${pkgs.iptables}/bin/iptables"

    # DNAT rule set for the ingress SSH forward ($1 = -I to add / -D to remove).
    # All four rules are guarded so a -D of an absent rule (or a duplicate -I)
    # never aborts.
    rules() {
      local act="$1"
      # Inbound from players, and host-local connections (e.g. admins), DNAT
      # the attempt port to the guest's SSH. --dst-type LOCAL keeps us from
      # rewriting traffic merely transiting on a coincidental port.
      "$ipt" -w -t nat "$act" PREROUTING -p tcp --dport "$port" -m addrtype --dst-type LOCAL \
        -j DNAT --to-destination "$gip:22" || true
      "$ipt" -w -t nat "$act" OUTPUT -p tcp --dport "$port" -m addrtype --dst-type LOCAL \
        -j DNAT --to-destination "$gip:22" || true
      # Masquerade the forwarded SSH so the guest always replies via the host.
      "$ipt" -w -t nat "$act" POSTROUTING -p tcp -d "$gip" --dport 22 -j MASQUERADE || true
      # Permit the DNATed connection past libvirt's per-network reject. -I puts
      # us ahead of that reject (requires libvirt's iptables firewall backend,
      # pinned in network.conf).
      "$ipt" -w "$act" FORWARD -p tcp -d "$gip" --dport 22 -j ACCEPT || true
    }

    # Put this domain's tap into hub mode: with MAC learning off the bridge
    # floods unknown-unicast to every port, so a promiscuous capture node sees
    # its siblings' traffic. Runs as root here — the service is unprivileged and
    # cannot touch the bridge. No teardown needed: the tap dies with the VM. At
    # the `started` phase libvirt has filled in the runtime tap name.
    hub_mode() {
      local tap
      tap="$(printf '%s' "$xml" \
        | ${pkgs.libxml2}/bin/xmllint --xpath "string(//devices/interface/target/@dev)" - 2>/dev/null || true)"
      [ -n "$tap" ] || return 0
      ${pkgs.iproute2}/bin/bridge link set dev "$tap" learning off flood on || true
    }

    case "$op" in
      start)
        if [ -n "$port" ] && [ -n "$gip" ]; then
          rules -D  # clear any stale copy first
          rules -I
        fi
        ;;
      started)
        # The runtime tap name is only filled into the XML once the domain is
        # started, so flip hub mode here — still before the guest's network is
        # up, so no sibling MAC is ever learned on this port.
        if [ "$hub" = "on" ]; then
          hub_mode
        fi
        ;;
      stopped)
        if [ -n "$port" ] && [ -n "$gip" ]; then
          rules -D
        fi
        ;;
    esac
  '';
in
{
  options.services.ctf-libvirt = {
    enable = mkEnableOption "libvirt networking (qemu hook + egress nwfilters) for CTF challenge VMs";

    libvirtUri = mkOption {
      type = types.str;
      default = "qemu:///system";
      description = "Libvirt URI used to define the nwfilters.";
    };

    egressAllowSubnets = mkOption {
      type = with types; listOf str;
      default = [ "10.4.2.0/24" ];
      description = ''
        Destination CIDR subnets every challenge VM may reach (the intended
        internal reach, e.g. the cache/git subnet), accepted BEFORE the
        `internalZones` fleet denylist. Defaults to the cache/git subnet.
      '';
    };

    internalZones = mkOption {
      type = with types; listOf str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
      ];
      description = ''
        Internal/fleet CIDRs every egress filter DROPS (cross-zone egress: other
        challenge-VM subnets, the arena fabric, overlays, any other private net).
        Dropped AFTER the per-attempt local exemption (gateway / own `/24`) and
        the `allowSubnets` allowlist, so a VM still reaches its own zone and the
        intended `allowSubnets` (e.g. the cache) but nothing else internal. An
        allow-all filter then accepts `0.0.0.0/0` for the public internet, so
        internet = everything MINUS these zones (plus `allowSubnets`). Defaults
        to all RFC1918 space (a superset of the fleet); narrow it only if some
        private range should be world-reachable.
      '';
    };

    egressFilters = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            allowAll = mkOption {
              type = types.bool;
              default = true;
              description = ''
                After the local exemption, `allowSubnets`, and the `internalZones`
                denylist, accept all remaining outbound (`0.0.0.0/0`), i.e. the
                public internet. This is the intentionally-open default so an
                unconfigured/dev deploy works; set false in prod to drop
                everything past the allowlist (the isolated posture reaching only
                its own zone + `allowSubnets`). Either way the fleet denylist
                applies, so no filter ever egresses cross-zone.
              '';
            };
            clusterLocal = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Which per-attempt traffic is exempted from the `internalZones`
                denylist. false (single-VM default): just the gateway + its DNS
                (`$GATEWAY`). true: the whole own `/24` (`$SUBNET`), so cluster
                siblings stay reachable. Set true for filters used by multi-node
                challenges; the domain template must pass the matching param.
              '';
            };
            allowSubnets = mkOption {
              type = with types; listOf str;
              default = [ ];
              description = ''
                When `allowAll` is false, the extra destination CIDRs (besides
                the gateway and its DNS) the VM may reach; everything else drops.
              '';
            };
            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = ''
                Raw libvirt nwfilter `<rule>` XML injected into the filter (before
                the final accept-all / drop). Escape hatch for policy the attrs
                don't cover, e.g. a cluster intra-/24 accept referencing
                `$SUBNET`, or per-protocol drops. Lower priority numbers first.
              '';
            };
            uuid = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                Optional pinned filter UUID. Pinning lets a redeploy update the
                filter in place even while a running domain references it (an
                unpinned redefine of an in-use filter needs an undefine, which
                fails "in use"). Built-ins pin theirs; leave null for custom.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Named libvirt egress nwfilters for challenge VMs, generated from a
        high-level policy (+ an `extraConfig` escape hatch). Two ship by default,
        both allow-all: `ctf-egress` (the default every VM references) and
        `ctf-egress-internet`, which the internet-needing erinyes challenges
        reference instead, so prod can keep those open while restricting the
        general default (`services.ctf-libvirt.egressFilters.ctf-egress.allowAll
        = false`). Peer-only isolation (capture_the_poll) uses a separate,
        non-egress `ctf-cluster-internal` filter.
      '';
    };

    openVmFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the VM SSH port range so the DNAT'd attempt ports are reachable.";
    };

    vmPortRange = {
      from = mkOption {
        type = types.port;
        default = 1024;
        description = "First host port forwarded to a challenge VM's SSH.";
      };
      to = mkOption {
        type = types.port;
        default = 1048;
        description = "Last host port forwarded to a challenge VM's SSH.";
      };
    };
  };

  config = mkIf cfg.enable {
    virtualisation.libvirtd.enable = true;

    # The two shipped egress filters (see egressFilters). Both allow-all so an
    # unconfigured/dev deploy just works; restrict them in prod. Defined here (not
    # as the option `default`) so a prod override of one still keeps the other.
    services.ctf-libvirt.egressFilters = {
      # The default every VM references, INCLUDING multi-node challenges (e.g.
      # capture_the_poll's ingress), so clusterLocal exempts the whole own /24
      # ($SUBNET) to keep cluster siblings reachable past the fleet denylist.
      # Every ctf-egress domain.xml.eex therefore passes $SUBNET. Pinned to the
      # UUID libvirt auto-assigned on the first deploy so existing hosts update in
      # place; allowSubnets (the intended internal reach) defaults to cache/git.
      # NOTE: because this now references $SUBNET, any live domain created before
      # the change (those passed only $GATEWAY) must be re-provisioned, else the
      # in-use redefine fails "unresolvable variable SUBNET".
      ctf-egress = {
        uuid = lib.mkDefault "1c4de10b-10dc-4972-808d-4db1a2258c09";
        clusterLocal = lib.mkDefault true;
        allowSubnets = lib.mkDefault cfg.egressAllowSubnets;
      };
      # Preferred by the internet-needing erinyes challenges. Reaches the
      # cache/git subnet (like ctf-egress) PLUS the public internet, but the
      # internalZones denylist still blocks the rest of the fleet (other VM
      # subnets, the arena fabric, overlays). clusterLocal exempts the whole own
      # /24 so erinyes main<->builder still talk.
      ctf-egress-internet = {
        uuid = lib.mkDefault "5c4de10b-10dc-4972-808d-4db1a2258c0d";
        clusterLocal = lib.mkDefault true;
        allowSubnets = lib.mkDefault cfg.egressAllowSubnets;
      };
    };

    # Install the per-attempt SSH port-forward + hub-mode hook.
    virtualisation.libvirtd.hooks.qemu.ctf-ssh-forward = qemuHook;

    # The hook's FORWARD ACCEPT must take precedence over the reject libvirt
    # adds for each NAT network. With the default nftables backend those
    # rejects live in a separate base chain that an iptables-compat ACCEPT
    # cannot preempt, so pin libvirt to its iptables backend, where a
    # top-inserted FORWARD rule wins.
    environment.etc."libvirt/network.conf".text = ''
      firewall_backend = "iptables"
    '';

    systemd.services.ctf-server-nwfilter =
      let
        # Build a named egress nwfilter from its policy. libvirt evaluates rules
        # by ascending priority, first match wins, so the order is: local
        # exemption (200/400), the `allowSubnets` allowlist (500), any
        # `extraConfig`, the `internalZones` fleet denylist (800), then the tail
        # (900/1000). EVERY filter drops the fleet, so none egresses cross-zone;
        # an allow-all filter additionally accepts the public internet on top.
        # `clusterLocal` picks the local exemption (gateway+DNS `$GATEWAY`, or the
        # whole own /24 `$SUBNET` for clusters). Pinning `uuid` lets a redeploy
        # update the filter in place while a running domain references it.
        mkFilterXml =
          name: f:
          let
            # tcp+udp accepts for the intended internal reach (e.g. the cache).
            allowRules = lib.concatMapStringsSep "\n" (
              cidr:
              let
                parts = lib.splitString "/" cidr;
                addr = builtins.elemAt parts 0;
                prefix = builtins.elemAt parts 1;
              in
              ''
                <rule action='accept' direction='out' priority='500'>
                  <ip dstipaddr='${addr}' dstipmask='${prefix}' protocol='tcp'/>
                </rule>
                <rule action='accept' direction='out' priority='500'>
                  <ip dstipaddr='${addr}' dstipmask='${prefix}' protocol='udp'/>
                </rule>''
            ) f.allowSubnets;

            # All-protocol drops for the fleet/internal zones (cross-zone block).
            denyRules = lib.concatMapStringsSep "\n" (
              cidr:
              let
                parts = lib.splitString "/" cidr;
                addr = builtins.elemAt parts 0;
                prefix = builtins.elemAt parts 1;
              in
              ''
                <rule action='drop' direction='out' priority='800'>
                  <ip dstipaddr='${addr}' dstipmask='${prefix}'/>
                </rule>''
            ) cfg.internalZones;

            # Per-attempt local traffic exempted from the fleet denylist.
            local =
              if f.clusterLocal then
                ''
                  <rule action='accept' direction='out' priority='200'>
                    <ip dstipaddr='$SUBNET' dstipmask='255.255.255.0'/>
                  </rule>''
              else
                ''
                  <rule action='accept' direction='out' priority='200'>
                    <ip dstipaddr='$GATEWAY'/>
                  </rule>
                  <rule action='accept' direction='out' priority='400'>
                    <udp dstipaddr='$GATEWAY' dstportstart='53'/>
                  </rule>
                  <rule action='accept' direction='out' priority='400'>
                    <tcp dstipaddr='$GATEWAY' dstportstart='53'/>
                  </rule>'';

            tail =
              if f.allowAll then
                "<rule action='accept' direction='out' priority='900'/>"
              else
                "<rule action='drop' direction='out' priority='1000'/>";
          in
          pkgs.writeText "${name}.xml" ''
            <filter name='${name}' chain='ipv4'>
              ${lib.optionalString (f.uuid != null) "<uuid>${f.uuid}</uuid>"}
              <filterref filter='allow-arp'/>
              <filterref filter='allow-dhcp'/>
              ${local}
              ${allowRules}
              ${f.extraConfig}
              ${denyRules}
              ${tail}
            </filter>
          '';

        # Strict peer-only isolation filter (NOT an internet egress filter), so
        # it lives outside `egressFilters`: a node on it reaches ONLY its cluster
        # siblings on the attempt's /24 (plus ARP/DHCP): no gateway, no DNS, no
        # internet. Used by the capture_the_poll web/poller pair; the ingress node
        # stays on the default egress filter for its SSH return path. Pinned UUID
        # for in-place redefine while a domain references it.
        clusterInternalFilterXml = pkgs.writeText "ctf-cluster-internal.xml" ''
          <filter name='ctf-cluster-internal' chain='ipv4'>
            <uuid>3c4de10b-10dc-4972-808d-4db1a2258c0b</uuid>
            <filterref filter='allow-arp'/>
            <filterref filter='allow-dhcp'/>
            <!-- Siblings on the attempt's own /24 only. SUBNET is injected
                 per-domain. -->
            <rule action='accept' direction='out' priority='300'>
              <ip dstipaddr='$SUBNET' dstipmask='255.255.255.0'/>
            </rule>
            <rule action='drop' direction='out' priority='1000'/>
          </filter>
        '';

        # Define every filter idempotently. With a pinned UUID a redefine updates
        # the filter in place — even while a running domain references it; the
        # undefine fallback only fires the one-time transition from a stale,
        # differently-UUID'd (or unpinned) filter.
        defineFilter = pkgs.writeShellScript "ctf-define-nwfilter" ''
          set -eu
          virsh="${config.virtualisation.libvirtd.package}/bin/virsh -c ${cfg.libvirtUri}"
          define() {
            if ! $virsh nwfilter-define "$1"; then
              $virsh nwfilter-undefine "$2" || true
              $virsh nwfilter-define "$1"
            fi
          }
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: f: "define ${mkFilterXml name f} ${name}") cfg.egressFilters
          )}
          define ${clusterInternalFilterXml} ctf-cluster-internal
        '';
      in
      {
        description = "Define the ctf challenge-VM libvirt egress network filters";
        wantedBy = [ "multi-user.target" ];
        after = [ "libvirtd.service" ];
        wants = [ "libvirtd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${defineFilter}";
        };
      };

    networking.firewall.allowedTCPPortRanges = optional cfg.openVmFirewall {
      inherit (cfg.vmPortRange) from to;
    };
  };
}
