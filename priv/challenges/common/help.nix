# Shared across every challenge VM: an offline `help` command.
#
# The challenge networks are host-only (no internet), so we bake the tldr
# pages into the image and render them locally with tealdeer's `--render`
# (which needs no cache). `help` on its own reprints the challenge banner
# plus a short orientation; `help <command>` shows tldr usage for a tool.
{ pkgs, ... }:

let
  # Pinned tldr-pages release, so the baked cache is reproducible.
  tldrSrc = pkgs.fetchFromGitHub {
    owner = "tldr-pages";
    repo = "tldr";
    rev = "v2.3";
    sha256 = "0af2idr3di6ircpgiwglmhjx9sdhzm89hn61260cx0vnx433vi5q";
  };

  # Ship the *complete* English page set for a Linux box: `common`
  # (cross-platform commands — the bulk) plus `linux` (linux-specific).
  # By tldr-pages policy any cross-platform command lives in `common` and
  # the per-OS dirs hold only OS-exclusive tools, so common + linux is
  # every page that applies here — not a curated subset. We drop only the
  # other operating systems (osx/windows/android/...) and non-English
  # translations, which are irrelevant on these VMs.
  tldrPages = pkgs.runCommand "ctf-tldr-pages" { } ''
    mkdir -p "$out"
    cp -r ${tldrSrc}/pages/common ${tldrSrc}/pages/linux "$out"/
  '';

  # Named `ctf-help`, not `help`: bash has a `help` builtin that would
  # shadow a PATH command of the same name.
  ctfHelp = pkgs.writeShellApplication {
    name = "ctf-help";
    runtimeInputs = [
      pkgs.tealdeer
      pkgs.coreutils
    ];
    text = ''
      pages="${tldrPages}"

      if [ "$#" -eq 0 ]; then
        if [ -f "$HOME/.ctf-banner" ]; then
          cat "$HOME/.ctf-banner"
        else
          echo "NixCTF challenge environment."
        fi
        printf '%s\n' \
          "" \
          "This machine has the tools you need for the challenge." \
          "For quick usage on a command, run:  ctf-help <command>   (e.g. ctf-help nix)" \
          ""
        exit 0
      fi

      cmd="$1"
      # Prefer a linux-specific page, then fall back to the common one.
      for section in linux common; do
        page="$pages/$section/$cmd.md"
        if [ -f "$page" ]; then
          exec tldr --render "$page"
        fi
      done

      echo "No help page for '$cmd'. Run 'ctf-help' for the challenge overview," >&2
      echo "or try '$cmd --help'." >&2
      exit 1
    '';
  };

  # A `tldr` that works offline. Stock tealdeer's `tldr <cmd>` reads a cache that
  # only `tldr --update` populates — which needs the network the challenge boxes
  # don't have, so it just errors and (worse) tells the player to run --update.
  # This wrapper renders the *baked* pages with `tldr --render` (the same
  # cache-free path ctf-help uses), so `tldr <cmd>` Just Works with no nag. It
  # shadows the stock binary (dropped from systemPackages below); flags like
  # --update/--list aren't meaningful on an offline box and get a clear message.
  ctfTldr = pkgs.writeShellApplication {
    name = "tldr";
    text = ''
      pages="${tldrPages}"

      if [ "$#" -eq 0 ] || [ "''${1#-}" != "$1" ]; then
        echo "usage: tldr <command>" >&2
        echo "(offline tldr pages baked into this box: common + linux; no network / --update)" >&2
        exit 1
      fi

      cmd="$1"
      for section in linux common; do
        page="$pages/$section/$cmd.md"
        if [ -f "$page" ]; then
          exec ${pkgs.tealdeer}/bin/tldr --render "$page"
        fi
      done

      echo "No tldr page for '$cmd' (offline set: common + linux). Try '$cmd --help'." >&2
      exit 1
    '';
  };
in
{
  # `ctf-help` and our offline `tldr` both render the baked pages via
  # `tldr --render`; the stock tealdeer binary is intentionally NOT in PATH (its
  # bare `tldr <cmd>` needs a network-populated cache — see ctfTldr).
  environment.systemPackages = [
    ctfHelp
    ctfTldr
  ];
}
