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

  basicNix1ImagePackage = pkgs.runCommand "ctf-basic-nix-1-vm-base" { } ''
    mkdir -p "$out"
    ln -s ${self.packages.${pkgs.system}.basic_nix_1}/nixos.qcow2 "$out/basic-nix_1.qcow2"
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
    # Match services.ctf-server.maxVmsPerTeam on the node so eval-driven limit
    # checks see the same cap the running service enforces.
    export CTF_SERVER_MAX_VMS_PER_TEAM="1"
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

  ctfStartBasicNix1 = pkgs.writeShellScriptBin "ctf-start-basic-nix-1" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.start_challenge_attempt(team, "basic-nix", 1); IO.puts(attempt.id)'
  '';

  ctfAttemptStatus = pkgs.writeShellScriptBin "ctf-attempt-status" ''
    set -euo pipefail

    exec ${pkgs.util-linux}/bin/runuser -u ctf-server -- psql ${psqlDatabaseUrl} --tuples-only --no-align --command \
      "SELECT status::text || ' ' || COALESCE(port::text, '<none>') FROM challenge_attempt WHERE \"group\" = 'basic-nix' AND level = 1 ORDER BY inserted_at DESC LIMIT 1;"
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

    deadline=$((SECONDS + 300))

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

  ctfWaitCompleted = pkgs.writeShellScriptBin "ctf-wait-completed" ''
    set -euo pipefail

    deadline=$((SECONDS + 300))

    while true; do
      status="$(ctf-attempt-status || true)"
      echo "challenge attempt status: ''${status:-<none>}"

      if [ "$status" = "completed 2201" ]; then
        exit 0
      fi

      if [ "$SECONDS" -ge "$deadline" ]; then
        ctf-dump-provisioning-state
        exit 1
      fi

      sleep 5
    done
  '';

  ctfWriteAttemptSsh = pkgs.writeShellScriptBin "ctf-write-attempt-ssh" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1); File.write!("/tmp/ctf.key", attempt.privkey); File.write!("/tmp/ctf.port", Integer.to_string(attempt.port))'
    cp /tmp/ctf.key /root/ctf.key
    cp /tmp/ctf.port /root/ctf.port
    chmod 600 /root/ctf.key
  '';

  ctfCompleteBasicNix1 = pkgs.writeShellScriptBin "ctf-complete-basic-nix-1" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'flag = File.read!("/tmp/ctf.flag") |> String.trim(); team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, challenge} = CtfServer.Challenges.get_challenge_by_group_and_level("basic-nix", 1); {:ok, score} = CtfServer.Challenge.score_challenge_attempt(challenge, team, flag); :ok = CtfServer.Challenges.complete_challenge_attempt(challenge, team, score)'
  '';

  # Wait until the latest basic-nix/1 attempt reaches an exact "<status> <port>"
  # string (or empty, once torn down). Generalizes ctf-wait-started/completed.
  ctfWaitStatus = pkgs.writeShellScriptBin "ctf-wait-status" ''
    set -euo pipefail

    target="''${1:-}"
    deadline=$((SECONDS + 300))

    while true; do
      status="$(ctf-attempt-status || true)"
      echo "challenge attempt status: ''${status:-<none>} (want: ''${target:-<none>})"

      if [ "$status" = "$target" ]; then
        exit 0
      fi

      if [ "$SECONDS" -ge "$deadline" ]; then
        ctf-dump-provisioning-state
        exit 1
      fi

      sleep 5
    done
  '';

  ctfPauseBasicNix1 = pkgs.writeShellScriptBin "ctf-pause-basic-nix-1" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1); {:ok, _} = CtfServer.Challenges.pause_challenge_attempt(attempt)'
  '';

  ctfResumeBasicNix1 = pkgs.writeShellScriptBin "ctf-resume-basic-nix-1" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1); {:ok, _} = CtfServer.Challenges.resume_challenge_attempt(attempt)'
  '';

  ctfRebuildBasicNix1 = pkgs.writeShellScriptBin "ctf-rebuild-basic-nix-1" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1); {:ok, _} = CtfServer.Challenges.rebuild_challenge_attempt(attempt)'
  '';

  ctfTeardownBasicNix1 = pkgs.writeShellScriptBin "ctf-teardown-basic-nix-1" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:ok, attempt} = CtfServer.Challenges.get_challenge_attempt_for_team(team, "basic-nix", 1); {:ok, _} = CtfServer.Challenges.teardown_challenge_attempt(attempt)'
  '';

  # With maxVmsPerTeam = 1 and a running basic-nix/1, starting a second VM
  # challenge must be refused before any provisioning happens.
  ctfStartExpectLimit = pkgs.writeShellScriptBin "ctf-start-expect-limit" ''
    set -euo pipefail

    ${ctfEval}/bin/ctf-eval 'team = CtfServer.Accounts.get_team_by_email("nixos-test@example.test"); {:error, :vm_limit_reached} = CtfServer.Challenges.start_challenge_attempt(team, "basic-nix", 2); IO.puts("limit-enforced")'
  '';

  ctfLoginViaHttp = pkgs.writeShellScriptBin "ctf-login-via-http" ''
    set -euo pipefail

    curl --fail --silent --show-error --max-time 10 --cookie-jar /root/ctf.cookies \
      http://localhost:4000/teams/log_in > /root/ctf-login.html

    csrf_token="$(
      grep -o 'name="_csrf_token"[^>]*value="[^"]*"' /root/ctf-login.html \
        | sed -n 's/.*value="\([^"]*\)".*/\1/p' \
        | head -n 1
    )"

    test -n "$csrf_token"

    curl --fail --silent --show-error --max-time 10 --location \
      --cookie /root/ctf.cookies \
      --cookie-jar /root/ctf.cookies \
      --form "_csrf_token=$csrf_token" \
      --form "team[email]=nixos-test@example.test" \
      --form "team[password]=correct horse battery staple" \
      http://localhost:4000/teams/log_in > /root/ctf-dashboard.html

    grep -q "NixOS Testers" /root/ctf-dashboard.html
  '';
in
testers.runNixOSTest {
  name = "ctf-server-challenge-vm";

  nodes.noc =
    { ... }:
    {
      imports = [
        self.nixosModules.ctf-server
      ];

      services.ctf-server = {
        enable = true;
        package = ctfServerPackage;
        vmBaseImagesPackage = basicNix1ImagePackage;
        host = "localhost";
        port = 4000;
        vmPortRange = {
          from = 2201;
          to = 2201;
        };
        # Exercise the per-team running-VM cap: with a single attempt up, a
        # second VM challenge must be refused (the test only runs one VM at a
        # time, so this doesn't constrain the rest of the flow).
        maxVmsPerTeam = 1;
        # openVmFirewall (default true) opens the challenge-VM SSH port range so
        # the player node can reach it.
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.postgresql
        ctfEval
        ctfRegisterTeam
        ctfStartBasicNix1
        ctfAttemptStatus
        ctfDumpProvisioningState
        ctfWaitStarted
        ctfWaitCompleted
        ctfWaitStatus
        ctfWriteAttemptSsh
        ctfCompleteBasicNix1
        ctfPauseBasicNix1
        ctfResumeBasicNix1
        ctfRebuildBasicNix1
        ctfTeardownBasicNix1
        ctfStartExpectLimit
        ctfLoginViaHttp
      ];

      virtualisation = {
        cores = 2;
        diskSize = 8192;
        memorySize = 4096;
        qemu.options = [
          "-cpu"
          "host"
        ];
      };
    };

  # The player: a separate machine that reaches the challenge VM only through
  # the noc host's forwarded SSH port, exercising the real
  # PREROUTING DNAT -> vnet -> guest path (not a same-host shortcut).
  nodes.player =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.openssh ];
    };

  testScript = ''
    import shlex

    start_all()

    noc.wait_for_unit("postgresql.service")
    noc.wait_for_unit("libvirtd.service")
    noc.wait_for_unit("ctf-server.service")
    noc.wait_for_open_port(4000)
    noc.wait_until_succeeds("curl --fail --silent --show-error --max-time 10 http://localhost:4000/")

    noc.succeed("test -s /var/lib/ctf-server/secrets/secret-key-base")
    noc.succeed("test -s /var/lib/ctf-server/secrets/release-cookie")
    noc.succeed("test -L /var/lib/ctf-server/vm-bases/basic-nix_1.qcow2")

    noc.succeed("ctf-register-team")
    noc.succeed("ctf-login-via-http")
    noc.succeed("ctf-start-basic-nix-1")

    noc.succeed("ctf-wait-started")
    noc.succeed("ctf-write-attempt-ssh")

    # Give the per-attempt key to the player and let it reach the guest only
    # through the noc host's forwarded SSH port -> PREROUTING DNAT -> vnet.
    player.wait_for_unit("multi-user.target")
    port = noc.succeed("cat /root/ctf.port").strip()
    key = noc.succeed("cat /root/ctf.key")
    player.succeed("umask 077; cat > /root/ctf.key <<'CTFKEY'\n" + key.rstrip() + "\nCTFKEY")
    player.succeed("chmod 600 /root/ctf.key")

    # Force IPv4: players reach the CTF host over IPv4 (nixc.tf is an A record),
    # and the port-forward hook DNATs with iptables (v4) only. Without -4 the
    # test driver's /etc/hosts resolves `noc` to its IPv6 address, which has no
    # DNAT behind it and times out.
    ssh_opts = "-4 -i /root/ctf.key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh_base = f"${ssh} {ssh_opts} -p {port} ctf@noc"

    # The guest DHCPs during boot (after the attempt reaches "started"); wait
    # for its pinned lease to appear.
    gip = noc.wait_until_succeeds(
        "${virsh} -c qemu:///system net-list --name | grep '^ctf-' | head -n1 | xargs -I{} ${virsh} -c qemu:///system net-dhcp-leases {} | awk '/ipv4/{print $5}' | cut -d/ -f1 | grep .",
        timeout=180,
    ).strip()
    print(f"guest leased {gip}")

    # First, reach the guest's sshd from the host over the vnet. This validates
    # the guest is up and, crucially, that the ctf-egress nwfilter lets it reply
    # to inbound connections (the return-traffic fix).
    noc.wait_until_succeeds(f"${ssh} {ssh_opts} -o ConnectTimeout=5 -p 22 ctf@{gip} true", timeout=180)

    # Then the real player path: player -> noc:<port> -> PREROUTING DNAT -> guest.
    player.wait_until_succeeds(f"${ssh} {ssh_opts} -o ConnectTimeout=5 -p {port} ctf@noc true", timeout=120)

    # An interactive login (no command) runs the login shell, which prints
    # the injected challenge banner via ~/.bash_profile.
    player.succeed(f"echo exit | {ssh_base} > /root/ctf-login-banner.txt 2>&1")
    player.succeed("grep -q 'NixCTF' /root/ctf-login-banner.txt")
    player.succeed("grep -q 'Your First Nix Expression' /root/ctf-login-banner.txt")

    # `ctf-help` reprints the banner, and `ctf-help <command>` renders a tldr
    # page entirely offline from the baked-in cache. Named with a
    # ctf_ prefix because bash has a `help` builtin.
    # Grep the per-challenge name, which only the injected banner can supply.
    # ctf-help falls back to a generic "NixCTF challenge environment." line
    # when ~/.ctf-banner is missing, so asserting on the title alone would
    # pass even if injection had failed.
    player.succeed(f"{ssh_base} 'ctf-help' | grep -q 'Your First Nix Expression'")
    player.succeed(f"{ssh_base} 'ctf-help tar' > /root/ctf-help-tar.txt")
    player.succeed("grep -qi 'archiv' /root/ctf-help-tar.txt")

    # Read the flag over SSH on the player, hand it back to the noc to score.
    flag = player.succeed(f"{ssh_base} 'sha256sum /home/ctf/challenge.txt | cut -d \" \" -f1'").strip()
    noc.succeed(f"printf '%s' {shlex.quote(flag)} > /tmp/ctf.flag")

    # Structural assertions while the domain/network run: the domain carries the
    # ctf-egress filterref, the pinned NIC MAC and the hook metadata (no SLiRP
    # hostfwd); the network is NAT-forwarded with a pinned lease; the nwfilter
    # is defined; and the hook installed the SSH DNAT into the vnet.
    dom = noc.succeed("${virsh} -c qemu:///system list --name | grep '^ctf-vm-'").strip()
    dom_xml = noc.succeed(f"${virsh} -c qemu:///system dumpxml {dom}")
    assert "filter='ctf-egress'" in dom_xml, "challenge domain missing ctf-egress filterref"
    assert "hostfwd" not in dom_xml, "release domain unexpectedly has a SLiRP hostfwd"
    assert "52:54:00:" in dom_xml, "challenge domain missing pinned NIC MAC"
    assert "ssh-port=" in dom_xml, "challenge domain missing hook metadata"

    net = noc.succeed("${virsh} -c qemu:///system net-list --name | grep '^ctf-'").strip()
    net_xml = noc.succeed(f"${virsh} -c qemu:///system net-dumpxml {net}")
    assert "mode='nat'" in net_xml, "challenge network is not NAT-forwarded"
    assert "<host mac=" in net_xml, "challenge network missing DHCP host reservation"

    noc.succeed("${virsh} -c qemu:///system nwfilter-list | grep ctf-egress")

    nat_rules = noc.succeed("iptables -w -t nat -S PREROUTING")
    assert f"--dport {port}" in nat_rules and "to-destination" in nat_rules, \
      "qemu hook did not install the SSH DNAT rule"

    # ---- Instance lifecycle: limit, pause/resume, rebuild, teardown ----

    def dom_state(d):
        return noc.succeed(f"${virsh} -c qemu:///system domstate {d}").strip()

    # NOTE: libvirt autostart flags are not asserted here. `virsh autostart`
    # (in start_vm/create_network) exits 0 — provisioning reaching "started"
    # already requires that — but the autostart symlink under /etc/libvirt is
    # not reliably effective in the ephemeral NixOS test VM, so `dominfo`
    # reports it disabled. It works on a real host; the pause/resume behaviour
    # below is what this test can verify.

    assert dom_state(dom) == "running", f"domain not running: {dom_state(dom)}"

    # Per-team running-VM cap (maxVmsPerTeam = 1): with basic-nix/1 up, starting
    # a second VM challenge is refused before any provisioning happens.
    noc.succeed("ctf-start-expect-limit | grep -q limit-enforced")

    # Pause: the guest powers off but the domain stays defined (the overlay,
    # network, and port are retained for resume). The status flips to paused
    # first and the worker powers the guest off asynchronously, so wait for the
    # domain to actually shut off.
    noc.succeed("ctf-pause-basic-nix-1")
    noc.succeed("ctf-wait-status 'paused 2201'")
    noc.wait_until_succeeds(
        f"${virsh} -c qemu:///system domstate {dom} | grep -q 'shut off'", timeout=120
    )
    noc.succeed(f"${virsh} -c qemu:///system list --all --name | grep -qx {dom}")

    # Resume: the guest powers back on. Crucially the per-attempt network is
    # reactivated first (a libvirtd restart can leave it inactive), so the guest
    # is reachable end-to-end again.
    noc.succeed("ctf-resume-basic-nix-1")
    noc.succeed("ctf-wait-started")
    noc.wait_until_succeeds(
        f"${virsh} -c qemu:///system domstate {dom} | grep -q running", timeout=120
    )
    player.wait_until_succeeds(f"{ssh_base} true", timeout=180)

    # Resume self-heals a missing network: pause, remove the per-attempt network
    # out of band, then resume and confirm it's recreated and reachable again.
    noc.succeed("ctf-pause-basic-nix-1")
    noc.succeed("ctf-wait-status 'paused 2201'")
    noc.wait_until_succeeds(
        f"${virsh} -c qemu:///system domstate {dom} | grep -q 'shut off'", timeout=120
    )
    noc.succeed(f"${virsh} -c qemu:///system net-destroy {net}")
    noc.succeed(f"${virsh} -c qemu:///system net-undefine {net}")
    noc.fail(f"${virsh} -c qemu:///system net-list --all --name | grep -qx {net}")
    noc.succeed("ctf-resume-basic-nix-1")
    noc.succeed("ctf-wait-started")
    noc.wait_until_succeeds(
        f"${virsh} -c qemu:///system net-list --name | grep -qx {net}", timeout=120
    )
    noc.wait_until_succeeds(
        f"${virsh} -c qemu:///system domstate {dom} | grep -q running", timeout=120
    )
    player.wait_until_succeeds(f"{ssh_base} true", timeout=180)

    # Rebuild: tear the instance down and provision a fresh one (new keypair,
    # same port). The old domain is gone, a new one exists, and it's reachable
    # with its freshly issued key.
    noc.succeed("ctf-rebuild-basic-nix-1")
    noc.succeed("ctf-wait-started")
    noc.wait_until_fails(
        f"${virsh} -c qemu:///system list --all --name | grep -qx {dom}", timeout=180
    )
    new_dom = noc.succeed("${virsh} -c qemu:///system list --name | grep '^ctf-vm-'").strip()
    assert new_dom != dom, "rebuild did not replace the domain"
    noc.succeed("ctf-write-attempt-ssh")
    new_key = noc.succeed("cat /root/ctf.key")
    player.succeed("umask 077; cat > /root/ctf.key <<'CTFKEY'\n" + new_key.rstrip() + "\nCTFKEY")
    player.succeed("chmod 600 /root/ctf.key")
    player.wait_until_succeeds(f"{ssh_base} true", timeout=180)
    dom = new_dom

    # The flag is deterministic per team, so the one read earlier still scores
    # the rebuilt instance. Complete the challenge, then tear it down entirely.
    noc.succeed("ctf-complete-basic-nix-1")
    noc.succeed("ctf-wait-completed")
    noc.succeed("curl --fail --silent --show-error --max-time 10 --cookie /root/ctf.cookies http://localhost:4000/dashboard > /root/ctf-completed-dashboard.html")
    noc.succeed("grep -q Completed /root/ctf-completed-dashboard.html")

    # Teardown removes the attempt record entirely and leaves no libvirt
    # resources behind for the attempt.
    noc.succeed("ctf-teardown-basic-nix-1")
    # No argument -> wait for an empty status, i.e. the attempt row is deleted.
    noc.succeed("ctf-wait-status")
    noc.fail("${virsh} -c qemu:///system list --all --name | grep '^ctf-vm-'")
    noc.fail("${virsh} -c qemu:///system net-list --all --name | grep '^ctf-'")
  '';
}
