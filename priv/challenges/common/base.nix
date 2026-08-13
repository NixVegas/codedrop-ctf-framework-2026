# Shared base configuration across every challenge VM.
#
# This is the block that used to be copy-pasted into every
# priv/challenges/<name>/vm.nix: the qemu-guest profile, the other common
# modules (help/boot/cache), root filesystem, SSH access, the standard
# package set, and the `ctf` user. A challenge vm.nix imports this and adds
# only whatever is specific to that challenge (e.g. offline build warmups).
{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./help.nix
    ./boot.nix
    ./cache.nix
    ./cluster-hosts.nix
  ];

  # Disk image settings. The built base image is deliberately small, but each
  # per-attempt overlay is created with a much larger virtual disk (see
  # CtfUtils.VMUtils.create_overlay). Grow the root partition and its ext4 fs to
  # fill that disk at boot so a challenge fetch/build has real headroom instead
  # of running out on the base image's tight free space.
  boot.growPartition = true;
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
    autoResize = true;
  };

  # Basic system
  system.stateVersion = "26.05";
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Point <nixpkgs> at the source that built this image, and resolve the
  # `nixpkgs` flake reference to the same local source, so challenges can
  # resolve nixpkgs without network access inside the offline VM.
  nix.nixPath = [ "nixpkgs=${pkgs.path}" ];
  nix.registry.nixpkgs.to = {
    type = "path";
    path = "${pkgs.path}";
  };

  # SSH access — authorized keys injected per-attempt via guestfish
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Give them some useful tools.
  environment.systemPackages = with pkgs; [
    nix
    vim
    curl
    git
    htop
    tmux
    nmap
    rogue
  ];

  users.users.ctf = {
    isNormalUser = true;
    home = "/home/ctf";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ ]; # injected per-attempt
  };
}
