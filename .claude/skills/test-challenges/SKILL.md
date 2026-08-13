---
name: test-challenges
description: Run the CTF challenge solvability nixosTests, report per-challenge pass/fail, and diagnose/fix failures. Use when asked to validate or test the challenges, check whether a challenge is solvable end-to-end, or before shipping/merging a challenge. Every VM challenge ships a nixosTest under `.#checks.x86_64-linux.*`; this runs them for real instead of hand-driving the app.
---

# Validate CTF challenges via their solvability nixosTests

Every challenge's `nixos/tests/<name>.nix` is wired into `flake.nix` as a flake
check. Each test provisions the **real** cluster and drives the intended solve
end to end. Treat this as the source of truth:

> **A challenge that "evaluates clean" or is "proven locally" but whose check has
> never run green is NOT done.** That exact gap once hid *nine* distinct bugs in
> a single challenge. Run the check.

## Give them room — never a loaded box

Each challenge test boots a nested-KVM VM at roughly 4 vCPU and ~10 GB. They are
heavy, they are slow (tens of minutes each), and they fail *falsely* when
starved.

**Never run these on a resource-contended machine.** Nested KVM starves and
tests time out with failures that look real and are not. Tell-tale in a test
log: a postgres checkpoint taking 100 s+ (`write=103 s`) where it is normally
sub-second — that is starvation, not a challenge bug. Re-run somewhere idle
before believing a timeout.

**If you have remote builders, use them.** Nix distributes the checks across
whatever `/etc/nix/machines` advertises with `kvm,nixos-test,big-parallel`, so
you can kick off the whole set at once. Pass `--max-jobs 0` to force every
derivation onto the remote builders and keep the local box out of it (without
it, nix runs a share of the heavy tests locally).

**Watch per-builder concurrency — oversubscription is what causes the false
timeouts.** Nix fills builders *greedily*, so a builder advertising a high
`maxJobs` will happily stack more heavy tests than its CPU can carry. Size it to
the hardware — roughly one test per 4–5 cores, and no more than ~8 on a large
box — or run the checks in batches so nothing stacks.

## Run the suite

1. Enumerate the challenge checks:
   ```sh
   nix eval .#checks.x86_64-linux --apply builtins.attrNames
   ```
   The per-challenge solvability tests are the ones to run:
   `ctf-server-capture-the-poll`.
   (Skip pure infra checks like `ctf-server-challenge-vm`/`challenge-help`
   unless asked.)

2. Build them all, distributed, keep going past failures, with live logs, and
   with the cache push off (dev iteration). **Run in the background** — each test
   is tens of minutes:
   ```sh
   NIX_CONFIG="post-build-hook =" nix build -L --keep-going --max-jobs 0 \
     … every challenge check that is slow …
   ```

3. Report **per-challenge pass/fail**. A check passed iff its output path is
   realized; a failed one is not:
   ```sh
   for c in <checks>; do
     if nix build --dry-run .#checks.x86_64-linux."$c" 2>&1 | grep -q "will be built"; then
       echo "$c: FAIL (not realized)"
     else
       echo "$c: PASS"
     fi
   done
   ```

## Caching: a green test won't re-run

Each check is a derivation, so a **passing** run is cached — re-running
`nix build` on unchanged inputs is an instant cache hit that does NOT re-execute
the test. Change challenge code → inputs change → it re-runs. To force a fresh
execution of an already-green test (e.g. to confirm a suspected starvation
timeout was a fluke, or to check flakiness), add `--rebuild`. Failed builds are
never cached, so a red/inconclusive test re-runs on its own next time.

## Diagnose a failure

- `nix log /nix/store/…-vm-test-run-<name>.drv` — the full test transcript
  (machine console + the testScript's asserts).
- A failure is usually either a **testScript assertion** (the solve never reached
  the flag) or a **challenge-mechanism bug**. Read the assert that fired.
- A node with no SSH ingress (e.g. a "buildee"/"target") is opaque from outside.
  For live debugging *outside* the test, provision a real attempt and drop a
  temporary `wheel` + `systemd-journal` `observer` user into that node's `.nix`
  (uncommitted — strip it before any commit) to SSH in and read
  `systemctl`/`journalctl`.
- Make build loops observable: if a challenge's service swallows stderr
  (`2>/dev/null`), a broken build is indistinguishable from "not done yet" — fix
  that first.

## Fix loop

Iterate on the **code** in the harness. Do NOT hand-drive the solve through the
running app (register → start → ssh → hack → teardown → rebuild) — that manual
UAT loop is a trap that wastes hours and pollutes diagnosis with its own debris.
Fix the code, re-run just the one failing check
(`NIX_CONFIG="post-build-hook =" nix build -L --max-jobs 0 .#checks.x86_64-linux.<name>`),
repeat until green, then re-run the full suite once to confirm nothing regressed.

## Before declaring done

- Every challenge check green.
- For anything that only timed out, confirm it was a real pass on a re-run (not
  masked by starvation).
- `mix precommit` still green (format / warnings-as-errors / unit tests).
