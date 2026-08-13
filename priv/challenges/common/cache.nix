# Shared across every challenge VM: use the NixVegas binary cache mirror
# in place of the default cache.nixos.org substituter.
{ lib, ... }:
{
  nix.settings.substituters = lib.mkForce [ "https://cache.nixos.lv" ];
}
