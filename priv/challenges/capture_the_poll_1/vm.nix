# Shared base for the capture-the-poll cluster nodes.
#
# Imports the common challenge base (SSH, ctf user, tooling, offline nixpkgs);
# per-role configuration lives in nodes/{web,poller,ingress}.nix, each of which
# imports THIS file. The flake builds one image per nodes/*.nix, not from this
# file directly (it has no `nodes/` of its own — it IS the base they override).
{ ... }:
{
  imports = [ ../common/base.nix ];
}
