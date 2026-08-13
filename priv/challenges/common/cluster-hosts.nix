# Shared cluster hostname resolution for multi-node challenges.
#
# A challenge attempt's nodes all sit on the attempt's own /24, addressed
# deterministically by node index: node 0 = <net>.2, node 1 = <net>.3, … (see
# CtfUtils.VMUtils.guest_ip/2). libvirt's NAT network runs dnsmasq, but
# guest-hostname resolution through it is unverified on a real host, and the
# per-attempt /root/.ssh/config only helps root, so a node that must reach a
# sibling by name (the nix-daemon offloading builds, an mTLS builder dialing the
# queue-runner, a player poking `ssh <sibling>` as the unprivileged ctf user)
# can otherwise fail to resolve it.
#
# This module lets any node declare `ctf.clusterHosts = { <name> = <index>; }`
# and derives each sibling's IP from the node's own /24 at boot, writing it into
# /etc/hosts (a store symlink, so it's rebuilt as a real file after activation).
# /etc/hosts wins over DNS, so this is a guaranteed fallback regardless of dnsmasq.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ctf.clusterHosts;
in
{
  options.ctf.clusterHosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    default = { };
    example = {
      builder = 0;
      queue-runner = 1;
    };
    description = ''
      Map of hostname to cluster node index to resolve via /etc/hosts at boot.
      Node index N is `<our /24>.(2 + N)` (node 0 = .2, node 1 = .3, …). Empty
      (the default) disables the resolver entirely, so single-node challenges
      are unaffected.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services.cluster-hosts = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # Ordered before nix-daemon so distributed-build offloads resolve siblings;
      # nodes with their own consumers (e.g. an mTLS builder) extend this list.
      before = [ "nix-daemon.service" ];
      # gawk + coreutils: the script pipes `ip … | awk … | cut … | head`. Without
      # gawk the awk stage is "command not found", `own` comes out empty, and the
      # entry is written as ".2 builder" (unresolvable). iproute2 alone is not enough.
      path = [
        pkgs.iproute2
        pkgs.gawk
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # network-online.target does not guarantee the DHCP lease has landed, so
        # poll until a global-scope IPv4 address exists. Without this the oneshot
        # can compute an empty `own` (→ a broken ".2 builder" entry) and, being a
        # oneshot, never correct it — leaving siblings permanently unresolvable.
        own=""
        for _ in $(seq 1 60); do
          own=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
          [ -n "$own" ] && break
          sleep 1
        done
        if [ -z "$own" ]; then
          echo "cluster-hosts: no global IPv4 address after 60s; not writing /etc/hosts" >&2
          exit 1
        fi
        net=$(echo "$own" | cut -d. -f1-3)
        tmp=$(mktemp)
        cat /etc/hosts > "$tmp" || true
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (host: index: ''echo "$net.${toString (2 + index)} ${host}" >> "$tmp"'') cfg
        )}
        rm -f /etc/hosts
        install -m 0644 "$tmp" /etc/hosts
        rm -f "$tmp"
      '';
    };
  };
}
