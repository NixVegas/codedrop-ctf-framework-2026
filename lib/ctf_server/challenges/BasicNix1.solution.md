# basic-nix/1 — "Your First Nix Expression" — solution

**Staff / author reference. Do not ship to players.**

## Scoring

Single flag, 100 points, all-or-nothing. The accepted token is

```
sha256( BasicNix1.generate_seed(team) )        # lowercase hex, 64 chars
```

where `generate_seed/1` is the first 16 hex characters of
`CtfServer.Flag.seed("basic-nix-1", team)`. Recomputed at scoring time, never
stored, and derived from the Phoenix `secret_key_base` — so it is not
computable from the team id alone.

## Topology

Single VM (`basic-nix_1.qcow2`), no internet. The 16-character seed is injected
per attempt at `/home/ctf/challenge.txt`.

**The file has no trailing newline** — its contents are exactly the 16 hex
characters. This matters: any solve that hashes a trailing `\n` produces the
wrong answer, and is the most likely reason a player insists their hash is
right.

## Solve

The intended path, in the REPL or straight from the shell:

```sh
nix eval --expr 'builtins.hashString "sha256" (builtins.readFile /home/ctf/challenge.txt)' --impure --raw
```

Equivalently, without Nix at all — useful for confirming a player's answer:

```sh
tr -d '\n' < ~/challenge.txt | sha256sum        # same 64 hex chars
```

Submit as `Nix{<64 hex>}`.

## Hint ladder

1. "`nix repl` gives you an interactive session; `:?` lists the commands."
2. "You need two builtins: one to read a file, one to hash a string."
3. "`builtins.hashString "sha256" (builtins.readFile ./challenge.txt)`."

## Common wrong answers

* **Hashing the filename rather than the contents** — `hashString "sha256"
  "./challenge.txt"`. Produces a valid-looking 64-hex string, so it fails
  scoring with no clue why.
* **`sha256sum ~/challenge.txt` including a newline** the player's editor added
  after opening and saving the file.
* Submitting the seed itself instead of its hash.
