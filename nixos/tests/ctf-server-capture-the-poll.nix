{
  lib,
  pkgs,
  testers,
  self,
  ...
}:

let
  ctfServerPackage = self.packages.${pkgs.system}.ctf-server;
  appDatabaseUrl = "postgresql://ctf-server@localhost/ctf_server?socket_dir=/run/postgresql";
  psqlDatabaseUrl = "postgresql://ctf-server@localhost/ctf_server?host=/run/postgresql";
  ssh = lib.getExe pkgs.openssh;
  virsh = lib.getExe' pkgs.libvirt "virsh";

  # The three per-role images this cluster challenge needs, under the runtime
  # names the provisioner reads.
  captureImagePackage = pkgs.runCommand "ctf-capture-vm-bases" { } ''
    mkdir -p "$out"
    ln -s ${
      self.packages.${pkgs.system}.capture_the_poll_1_web
    }/nixos.qcow2 "$out/capture-the-poll_1_web.qcow2"
    ln -s ${
      self.packages.${pkgs.system}.capture_the_poll_1_poller
    }/nixos.qcow2 "$out/capture-the-poll_1_poller.qcow2"
    ln -s ${
      self.packages.${pkgs.system}.capture_the_poll_1_ingress
    }/nixos.qcow2 "$out/capture-the-poll_1_ingress.qcow2"
  '';

  ctfEval = pkgs.writeShellScriptBin "ctf-eval" ''
    set -euo pipefail

    if [ "$(id -un)" != "ctf-server" ]; then
      exec ${pkgs.util-linux}/bin/runuser -u ctf-server -- "$0" "$@"
    fi

    export HOME="/var/lib/ctf-server"
    export SECRET_KEY_BASE="$(tr -d '\n' < /var/lib/ctf-server/secrets/secret-key-base)"
    export RELEASE_COOKIE="$(tr -d '\n' < /var/lib/ctf-server/secrets/release-cookie)"
    export DATABASE_URL="${appDatabaseUrl}"
    export POOL_SIZE="10"
    export CTF_SERVER_VM_BASE_IMAGE_PATH="/var/lib/ctf-server/vm-bases"
    export CTF_SERVER_VM_OVERLAY_PATH="/var/lib/ctf-server/overlays"
    export CTF_SERVER_VM_PORT_RANGE="2201..2201"
    export CTF_SERVER_VM_SSH_HOST="localhost"
    export CTF_SERVER_VM_LIBVIRT_URI="qemu:///system"

    expression="$1"
    shift

    exec timeout 60 ${ctfServerPackage}/bin/ctf_server eval "Application.ensure_all_started(:ctf_server); $expression" "$@"
  '';

  ctfRegisterTeam = pkgs.writeShellScriptBin "ctf-register-team" ''
    set -euo pipefail
    ${ctfEval}/bin/ctf-eval 'attrs = %{name: "NixOS Testers", email: "nixos-test@example.test", password: "correct horse battery staple"}; {:ok, team} = CtfServer.Accounts.register_team(attrs); IO.puts(team.id)'
  '';

  ctfStartCapture = pkgs.writeShellScriptBin "ctf-start-capture" ''
    set -euo pipefail
    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.start_challenge_attempt(team, "capture-the-poll", 1); IO.puts(attempt.id)'
  '';

  ctfAttemptStatus = pkgs.writeShellScriptBin "ctf-attempt-status" ''
    set -euo pipefail
    exec ${pkgs.util-linux}/bin/runuser -u ctf-server -- psql ${psqlDatabaseUrl} --tuples-only --no-align --command \
      "SELECT status::text || ' ' || COALESCE(port::text, '<none>') FROM challenge_attempt WHERE \"group\" = 'capture-the-poll' AND level = 1 ORDER BY inserted_at DESC LIMIT 1;"
  '';

  ctfDumpProvisioningState = pkgs.writeShellScriptBin "ctf-dump-provisioning-state" ''
    set -euo pipefail
    echo "ctf-server journal:"
    journalctl -u ctf-server.service --no-pager -n 200 || true
    echo "recent oban jobs:"
    ${pkgs.util-linux}/bin/runuser -u ctf-server -- psql ${psqlDatabaseUrl} --tuples-only --expanded --command \
      "SELECT state, queue, worker, args, errors FROM oban_jobs ORDER BY inserted_at DESC LIMIT 10;" || true
    echo "libvirt domains:"
    ${virsh} -c qemu:///system list --all || true
    echo "libvirt networks:"
    ${virsh} -c qemu:///system net-list --all || true
  '';

  ctfWaitStarted = pkgs.writeShellScriptBin "ctf-wait-started" ''
    set -euo pipefail
    deadline=$((SECONDS + 420))
    while true; do
      status="$(ctf-attempt-status || true)"
      echo "challenge attempt status: ''${status:-<none>}"
      if [ "$status" = "started 2201" ]; then
        exit 0
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        ctf-dump-provisioning-state
        exit 1
      fi
      sleep 5
    done
  '';

  # Per-attempt SSH key + the ingress node's pinned IP (node index 2), written
  # where the test can read them.
  ctfWriteAttemptSsh = pkgs.writeShellScriptBin "ctf-write-attempt-ssh" ''
    set -euo pipefail
    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.get_challenge_attempt_for_team(team, "capture-the-poll", 1); File.write!("/tmp/ctf.key", attempt.privkey); File.write!("/tmp/ctf.ingress_ip", CtfUtils.VMUtils.guest_ip(attempt.id, 2))'
    cp /tmp/ctf.key /root/ctf.key
    cp /tmp/ctf.ingress_ip /root/ctf.ingress_ip
    chmod 600 /root/ctf.key
  '';

  # `ctf-eval` emits an app-start log line before our output, so pull just the
  # 64-hex flag out of the eval's stdout.
  ctfExpectedFlag = pkgs.writeShellScriptBin "ctf-expected-flag" ''
    set -euo pipefail
    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); IO.puts(CtfServer.Challenges.CaptureThePoll.expected_flag(team))' \
      | grep -oE '[0-9a-f]{64}' | tail -n 1
  '';

  # Runs ON the ingress node (piped in over SSH). Captures ~20s of traffic on
  # the attempt NIC and prints the first 64-hex flag it sees on the wire.
  # Runs ON the ingress: capture ~30s of peer traffic (SSH excluded) and print
  # the first 64-hex flag seen crossing the wire.
  ctfCaptureScript = pkgs.writeShellScript "ctf-capture" ''
    set -eu
    iface="$(ip -o -4 addr show scope global | awk '{print $2; exit}')"
    timeout 40 tshark -i "$iface" -f "not port 22" -w /tmp/cap.pcap -a duration:30 >/dev/null 2>&1 || true
    grep -aoE '[0-9a-f]{64}' /tmp/cap.pcap | head -n 1
  '';
in
testers.runNixOSTest {
  name = "ctf-server-capture-the-poll";

  nodes.noc =
    { ... }:
    {
      imports = [ self.nixosModules.ctf-server ];

      services.ctf-server = {
        enable = true;
        package = ctfServerPackage;
        vmBaseImagesPackage = captureImagePackage;
        host = "localhost";
        port = 4000;
        vmPortRange = {
          from = 2201;
          to = 2201;
        };
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.postgresql
        pkgs.openssh
        ctfEval
        ctfRegisterTeam
        ctfStartCapture
        ctfAttemptStatus
        ctfDumpProvisioningState
        ctfWaitStarted
        ctfWriteAttemptSsh
        ctfExpectedFlag
      ];

      # Three nested KVM guests per attempt — give the noc room.
      virtualisation = {
        cores = 4;
        diskSize = 16384;
        memorySize = 8192;
        qemu.options = [
          "-cpu"
          "host"
        ];
      };
    };

  testScript = ''
    start_all()

    noc.wait_for_unit("postgresql.service")
    noc.wait_for_unit("libvirtd.service")
    noc.wait_for_unit("ctf-server.service")
    noc.wait_for_open_port(4000)
    noc.wait_until_succeeds("curl --fail --silent --show-error --max-time 10 http://localhost:4000/")

    # All three per-role images are linked into the runtime image dir.
    noc.succeed("test -L /var/lib/ctf-server/vm-bases/capture-the-poll_1_web.qcow2")
    noc.succeed("test -L /var/lib/ctf-server/vm-bases/capture-the-poll_1_poller.qcow2")
    noc.succeed("test -L /var/lib/ctf-server/vm-bases/capture-the-poll_1_ingress.qcow2")

    noc.succeed("ctf-register-team")
    noc.succeed("ctf-start-capture")
    noc.succeed("ctf-wait-started")
    noc.succeed("ctf-write-attempt-ssh")

    # The cluster stands up three domains and one network for the attempt.
    domains = noc.succeed("${virsh} -c qemu:///system list --name | grep '^ctf-vm-' | sort").splitlines()
    print("cluster domains:", domains)
    assert len(domains) == 3, f"expected 3 cluster domains, got {domains}"
    for role in ("web", "poller", "ingress"):
        assert any(d.endswith(f"-{role}") for d in domains), f"missing {role} domain in {domains}"

    # SSH into the ingress node over the vnet and sniff the web<->poller HTTP.
    gip = noc.succeed("cat /root/ctf.ingress_ip").strip()
    ssh_opts = "-4 -i /root/ctf.key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    ssh_base = f"${ssh} {ssh_opts} ctf@{gip}"

    noc.wait_until_succeeds(f"{ssh_base} true", timeout=240)

    captured = noc.succeed(f"{ssh_base} 'bash -s' < ${ctfCaptureScript}").strip()
    print("captured off the wire:", captured)

    expected = noc.succeed("ctf-expected-flag").strip()
    assert captured == expected, f"captured {captured!r} != expected flag {expected!r}"
  '';
}
