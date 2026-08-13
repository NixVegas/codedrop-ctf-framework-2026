# Web node — serves the per-team flag page over PLAIN HTTP so the poller can
# fetch it and the ingress node can capture it off the wire. Peers-only: this
# node uses the ctf-cluster-internal egress filter (no gateway/internet).
#
# The flag file is injected per-attempt at /var/www/flag.txt by start_cluster.
{ ... }:
{
  imports = [ ../vm.nix ];

  # This is web = node 0; resolve the cluster siblings by name (poller = node 1,
  # ingress = node 2) via common/cluster-hosts.nix. Peers still address by the
  # injected per-attempt IP too, but names make the topology legible.
  ctf.clusterHosts = {
    poller = 1;
    ingress = 2;
  };

  services.nginx = {
    enable = true;
    virtualHosts."flag" = {
      default = true;
      root = "/var/www";
    };
  };

  # The challenge VM firewall is on by default (only SSH is auto-opened), so
  # let the poller reach the flag server.
  networking.firewall.allowedTCPPorts = [ 80 ];
}
