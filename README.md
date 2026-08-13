# CtfServer

> ## ⚠️ Free as in kittens
>
> This is the CTF framework that ran the NixVegas CTF, dropped roughly as it
> stood on the day. It is **not** a product, it is a **cat**. It is affectionate,
> it works, and it will absolutely knock something off a shelf while you are
> looking the other way.
>
> **There is no support, no warranty, and no roadmap.** Nobody is on call for
> this. Issues and PRs may go unread. If you break it, you get to keep both
> parts — and both parts are yours to feed, house, and take to the vet.
>
> Things you should assume are true until you check for yourself:
>
> - **It provisions real VMs and rewrites real firewall rules.** Run it on a
>   machine you are willing to lose, on a network you are willing to explain.
> - **Some defaults are baked for the event that ran it** — the challenge VMs
>   point at a binary cache that is not yours (`priv/challenges/common/cache.nix`),
>   and the egress allowlist defaults to a subnet that is not yours
>   (`services.ctf-server.egressAllowSubnets`). Both fail in ways that look like
>   your fault.
> - **There is no admin bootstrap in production.** The NixOS module only runs
>   migrations; `priv/repo/seeds.exs` is a dev convenience. Your first admin is a
>   manual `UPDATE teams SET is_admin = true`.
> - **The mail adapter is a stub.** Password-reset mail goes nowhere until you
>   configure a real Swoosh adapter.
> - **Flags are derived from `SECRET_KEY_BASE`.** Rotate it and every unsolved
>   per-team flag changes underneath your players.
>
> It is a good cat. Pet it at your own risk.

## Running it locally

Everything happens inside the flake's dev shell — `mix` is not on `PATH`
without it, and entering it starts a repo-local PostgreSQL:

```sh
nix develop
mix setup        # deps, database, migrations, seeds, assets
mix phx.server
```

Then http://localhost:4000. `mix setup` seeds an admin team you can log in
with: `ctf_admin@localhost` / `adminadmin`.

`HACKING.md` covers challenge authoring, VM base images, and the `mix ctf.*`
tasks. `mix precommit` (format, warnings-as-errors, tests) is the gate.

## NixOS module

The flake exposes a production release package at `.#ctf-server` and a NixOS
module at `.#nixosModules.ctf-server`.

```nix
{
  imports = [ inputs.ctf-server.nixosModules.ctf-server ];

  services.ctf-server = {
    enable = true;
    host = "ctf.example.org";
  };
}
```

The web listener and generated public URLs are configured separately. By
default the service listens on `[::]:4000` and generates `http://<host>:4000`
URLs. For direct HTTP, set `listenAddress` and `port` as needed. When serving
behind a TLS reverse proxy, keep the listener local and set `urlScheme` and
`urlPort` to the externally visible URL:

```nix
services.ctf-server = {
  host = "ctf.example.org";
  listenAddress = "localhost";
  port = 4000;
  urlScheme = "https";
  urlPort = 443;
};
```

By default the module creates a local PostgreSQL database, enables system
libvirt, exposes built challenge VM bases under
`/var/lib/ctf-server/vm-bases`, and writes per-attempt overlays under
`/var/lib/ctf-server/overlays`. It also generates persistent Phoenix and BEAM
release secrets under `/var/lib/ctf-server/secrets` unless
`secretKeyBaseFile` or `releaseCookieFile` are configured explicitly. The local
database URL defaults to PostgreSQL's `/run/postgresql` Unix socket; set
`database.socketDir = null` with `database.host` and `database.port` to use TCP.

## NixOS tests

The flake exposes a NixOS VM test that exercises the packaged module and a full
challenge lifecycle:

```sh
nix eval .#checks.x86_64-linux.ctf-server-challenge-vm.drvPath
env XDG_CACHE_HOME=/tmp/nix-cache nix build -L .#checks.x86_64-linux.ctf-server-challenge-vm --no-link
```

The test boots a NixOS machine with `services.ctf-server` enabled, waits for
PostgreSQL, libvirt, and Phoenix, registers and logs in a team, starts Basic Nix
1 through the CTF server's challenge provisioning path, SSHes into the challenge
VM, submits the flag, and verifies the dashboard marks it completed.

Run it on an x86_64-linux machine that can run NixOS VM tests with KVM. The
challenge VM is started by the CTF server inside the test VM, so nested
virtualization needs to be available for the full libvirt flow. The first run
can take several minutes because it builds the release and boots both the test
machine and the challenge VM; `-L` keeps the VM and service logs visible.

