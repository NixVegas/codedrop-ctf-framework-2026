# Poller node — periodically fetches the web node's flag page in cleartext, so
# there is a steady stream of flag-bearing HTTP for the ingress to capture.
# Peers-only: uses the ctf-cluster-internal egress filter.
#
# The target URL (the web node's per-attempt IP) is injected at
# /etc/ctf/poll-url by start_cluster.
{ pkgs, ... }:
{
  imports = [ ../vm.nix ];

  # This is poller = node 1; resolve the cluster siblings by name (web = node 0,
  # ingress = node 2) via common/cluster-hosts.nix. The poll URL is still the
  # injected per-attempt IP, but `http://web/` would now resolve too.
  ctf.clusterHosts = {
    web = 0;
    ingress = 2;
  };

  systemd.services.ctf-poller = {
    description = "capture-the-poll periodic fetcher";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig.Restart = "always";
    script = ''
      url="$(cat /etc/ctf/poll-url)"
      while true; do
        ${pkgs.curl}/bin/curl --silent --max-time 5 "$url" >/dev/null || true
        sleep 5
      done
    '';
  };
}
