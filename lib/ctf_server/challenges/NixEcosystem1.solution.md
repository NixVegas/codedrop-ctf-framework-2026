# nix-ecosystem/1 — "Reading the Source" — solution

**Staff / author reference. Do not ship to players.**

> ## Answer (pinned against nixos-26.05)
>
> `@answer` is `nixos/modules/services/web-servers/nginx/default.nix:237` —
> line 237 is the `${optionalString cfg.recommendedGzipSettings` block opener
> (the `mkOption` *declaration* is line 627, the common wrong answer). Flag:
> `sha256("nixos/modules/services/web-servers/nginx/default.nix:237")` =
> `4efb0c226cd8d3819c69c04ca4fe8c63c293669ab63b59e749b90d4e650669a0`.
>
> **Re-verify before the event.** The on-site Forgejo mirrors the `nixos-26.05`
> branch tip (~6 h delay), not a frozen pin, so a commit that shifts this block
> moves the line. Re-check against the deployed revision, not upstream master.

## Scoring

Single flag, 100 points, all-or-nothing. **Universal** — same answer for every
team.

```
flag = sha256("<path>:<line>")        # lowercase hex, 64 chars
```

`NixEcosystem1.expected_flag/0`. No VM (`vm_base_config → nil`).

## The target

In `nixos/modules/services/web-servers/nginx/default.nix`, the block guarded by
`optionalString cfg.recommendedGzipSettings` — the one that emits the real
`gzip on; gzip_types …;` directives. The answer is the line where that block
**begins**.

Path is relative to the nixpkgs root, forward slashes, no leading `./`.

## Solve

```sh
# in the nixpkgs checkout the Forgejo serves
grep -n "recommendedGzipSettings" nixos/modules/services/web-servers/nginx/default.nix
# take the line where the optionalString block starts, then:
printf '%s' 'nixos/modules/services/web-servers/nginx/default.nix:<line>' | sha256sum
```

Submit as `Nix{<64 hex>}`.

## Hint ladder

1. "`recommendedGzipSettings` is an option — but options don't emit config.
   Something else does."
2. "Grep the nginx module for the option name; you want the place it's *used*,
   not where it's declared."
3. "The `optionalString` block. First line of it."

## Common wrong answers

* **The option *declaration* line** rather than the `optionalString` use — the
  single likeliest miss, since grep hits the declaration first.
* Off-by-one: the line of the `gzip on;` text rather than the line the block
  opens on.
* An absolute path, a leading `./`, or a trailing newline in the hashed string
  (`echo` instead of `printf '%s'`).
* Hashing against **upstream** nixpkgs rather than the revision the on-site
  Forgejo serves. Same file, different line.
