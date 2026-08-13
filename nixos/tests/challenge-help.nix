{
  lib,
  pkgs,
  testers,
  ...
}:
# Guards the shared offline help tooling (priv/challenges/common/help.nix): on a
# box with no network, `tldr <cmd>` must render a baked page cleanly — not error
# about a missing cache or tell the player to run `tldr --update`.
testers.runNixOSTest {
  name = "challenge-help";

  nodes.machine =
    { ... }:
    {
      imports = [ ../../priv/challenges/common/help.nix ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # `tldr <cmd>` renders a baked page, offline, to stdout.
    out = machine.succeed("tldr ls")
    assert "ls" in out.lower(), f"tldr did not render the ls page:\n{out}"

    # ...and prints NO cache/update nag on stderr (the whole point of this test).
    err = machine.succeed("tldr ls 2>&1 1>/dev/null || true")
    assert "update" not in err.lower(), f"unexpected update nag on stderr:\n{err}"
    assert "cache" not in err.lower(), f"unexpected cache message on stderr:\n{err}"

    # ctf-help renders too (same cache-free path).
    machine.succeed("ctf-help ls")

    # Flags that only make sense online get a clear message, not a cache error.
    flags = machine.fail("tldr --update 2>&1")
    assert "update" not in flags.lower() or "offline" in flags.lower(), flags

    # An unknown page fails cleanly (no crash, no cache talk).
    machine.fail("tldr thiscommanddoesnotexist")
  '';

  meta.maintainers = [ ];
}
