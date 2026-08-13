# capture-the-poll/1 — "Capture the Poll" — solution

**Staff / author reference. Do not ship to players.**

## Scoring

Single flag, 100 points, all-or-nothing. **Per-team.**

```
seed = first 16 hex chars of CtfServer.Flag.seed("capture-the-poll-1", team)
flag = CaptureThePoll.expected_flag(team)      # 64 lowercase hex
```

Recomputed at scoring time, never stored.

## Topology

A **three-node cluster** — the reference implementation of the cluster-per-attempt
infrastructure, and the reason `VMUtils.start_cluster/3` exists:

| Role | Image | Job |
|---|---|---|
| `ingress` | `capture-the-poll_1_ingress.qcow2` | the box the player SSHes into; carries `tcpdump`/`tshark` |
| `web` | `capture-the-poll_1_web.qcow2` | serves the flag over plain HTTP |
| `poller` | `capture-the-poll_1_poller.qcow2` | fetches that page every few seconds |

Only the ingress gets an SSH port. The flag is **never shown to the player
directly** — it exists only in HTTP traffic between the other two nodes, on the
shared per-attempt network the ingress can see.

`vm_base_config/0` returns the shared base purely so `Challenges.needs_vm?/1`
sees a VM challenge and a port is checked out; that string is not what gets
built.

## Solve

```sh
# on the ingress
tshark -i eth0 -Y http -T fields -e http.file_data
```

Or capture then read:

```sh
sudo tcpdump -i eth0 -A -s0 'tcp port 80'
```

Wait a few seconds for the poller's next request; the flag is in the response
body in the clear.

## Hint ladder

1. "You're not meant to find it on your own box. Two other machines are talking."
2. "It's plain HTTP. You have `tcpdump` and `tshark`."
3. "`tshark -i eth0 -Y http -T fields -e http.file_data`, then wait for the next
   poll."

## Common wrong answers

* Searching the ingress filesystem for the flag — it genuinely isn't there.
* Sniffing the SSH session instead of the HTTP traffic (filter with
  `not port 22`, as the solvability test does).
* Giving up before the next poll interval elapses.

## Automated coverage

`nixos/tests/ctf-server-capture-the-poll.nix` drives the whole thing: it stands
up the cluster, sniffs the attempt NIC with `tshark`, extracts the first 64-hex
string off the wire, and asserts it equals `CaptureThePoll.expected_flag/1` for
the test team. If this challenge ever breaks, that check catches it — run it via
the `test-challenges` skill.
