# Ingress node — the box the team SSHes into. Carries packet-capture tooling so
# the team can sniff the web<->poller HTTP off the (hub-mode) bridge and recover
# the flag. Uses the standard ctf-egress filter: it needs the gateway for the
# SSH return path, and capture is inbound, so it needs no intra-/24 egress rule.
{ pkgs, ... }:
{
  imports = [ ../vm.nix ];

  # This is ingress = node 2; resolve the cluster siblings by name (web = node 0,
  # poller = node 1) via common/cluster-hosts.nix, so the team can refer to the
  # sniff targets by name.
  ctf.clusterHosts = {
    web = 0;
    poller = 1;
  };

  # dumpcap with capture capabilities + a `wireshark` group, so the ctf user
  # can capture unprivileged (no sudo needed to sniff).
  programs.wireshark = {
    enable = true;
    package = pkgs.wireshark-cli;
  };
  users.users.ctf.extraGroups = [ "wireshark" ];

  environment.systemPackages = [ pkgs.tcpdump ];
}
