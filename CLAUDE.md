# CtfServer — notes for AI assistants (and humans)

Phoenix/Elixir app that runs the NixVegas CTF: teams register, start challenges,
and submit flags. Most challenges provision a per-attempt libvirt VM; some are
"no-VM" and solved against external resources (see `Challenges.needs_vm?/1`).

## Pre-event punchlist

Some things must be set or done before a CTF goes live and cannot be settled in
the code alone — placeholders pinned against the deployed environment (e.g. a
challenge `@answer` that names a file and line in a moving branch), operational
setup, and manual steps someone has to take.

**When you discover such an item but it is not part of the change at hand, say
so explicitly in your reply and leave a marker in the code** rather than fixing
it silently or letting it disappear. Whoever runs the event needs a single
place listing everything in the "do not ship without this" category; keep that
list wherever this deployment tracks its work.

## Before every commit

Run the pre-commit gate and keep it green:

```sh
mix precommit
```

It runs, in order:

1. `format --check-formatted` — fails if anything is unformatted. Fix with `mix format`.
2. `compile --warnings-as-errors` — no warnings allowed.
3. `test` — the full suite (auto-creates/migrates the test DB).

If `mix precommit` passes, the change is ready to commit. Do not commit with it
red; if a pre-existing failure is genuinely out of scope, say so explicitly
rather than silently skipping it.

## Conventions

- **Formatting is enforced by `mix precommit`.** Run `mix format` before committing;
  don't hand-format or leave the tree dirty.
- **Challenges** implement the `CtfServer.Challenge` protocol + `CtfServer.ChallengeBehavior`.
  A challenge needs no VM iff its `vm_base_config/0` returns `nil` — that is the
  signal `Challenges.needs_vm?/1` reads and the provisioner branches on. Do not use
  `function_exported?` as the no-VM signal.
  **Provisioning goes through `CtfUtils.VMUtils.start_cluster/3` + `teardown_cluster/1`
  for every VM challenge (single-VM is a cluster of one).** See `HACKING.md` →
  "Adding a new challenge" for the full authoring guide, including multi-node clusters
  (per-role images, per-node egress filters, `hub_mode`).
- Shell commands baked into challenge VMs are kebab-case (`ctf-help`, not `ctf_help`).

## Verifying end-to-end

The `verify` skill and the NixOS VM test (`README.md` → "NixOS tests") exercise a
full challenge lifecycle. Unit/integration tests cover the no-VM path without libvirt.
