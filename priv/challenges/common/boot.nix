# Shared across every challenge VM: bootloader and console, arch-conditional.
#
# citadel/production runs x86_64; this dev box (and any aarch64 host) needs
# a UEFI-bootable image instead of legacy grub/SeaBIOS. Domain arch = host
# arch = base-image arch by construction (see lib/ctf_utils/vm_utils.ex), so
# this module picks its branch off the build platform, not a flag.
{ pkgs, ... }:
{
  boot.loader.grub =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      {
        enable = true;
        efiSupport = true;
        efiInstallAsRemovable = true;
        device = "nodev";
      }
    else
      {
        enable = true;
        device = "/dev/vda";
        extraConfig = ''
          serial --unit=0 --speed=115200
          terminal_input serial console
          terminal_output serial console
        '';
      };

  boot.kernelParams =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      [ "console=ttyAMA0,115200" ]
    else
      [ "console=ttyS0,115200" ];
}
