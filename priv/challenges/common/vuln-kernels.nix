# Deliberately-vulnerable kernels for the erinyes LPE challenges.
#
# Each entry pins a specific vulnerable point release by SOURCE OVERRIDE on the
# current nixpkgs 6.18 kernel infrastructure — we do NOT roll nixpkgs back.
# Built with a slim, virtio-only config (autoModules = false, everything
# built-in) so there is no initrd module juggling and the from-source build
# stays small.
{ pkgs, lib }:

let
  inherit (lib.kernel) yes;

  # Minimal config for a libvirt/qemu guest that must also run offline Nix
  # builds. Everything built-in. If the VM fails to boot, widen this (see the
  # erinyes plan's Task 5 iteration loop) or fall back to autoModules = true.
  slimConfig = {
    # virtio transport + devices
    VIRTIO = yes;
    VIRTIO_PCI = yes;
    VIRTIO_MMIO = yes;
    VIRTIO_BLK = yes;
    VIRTIO_NET = yes;
    VIRTIO_CONSOLE = yes;
    VIRTIO_BALLOON = yes;
    HW_RANDOM_VIRTIO = yes;
    SCSI_VIRTIO = yes;
    BLK_DEV_SD = yes;
    SCSI = yes;
    SCSI_LOWLEVEL = yes;

    # PCI / core buses
    PCI = yes;
    PCI_MSI = yes;

    # filesystems
    EXT4_FS = yes;
    EXT4_USE_FOR_EXT2 = yes;
    TMPFS = yes;
    TMPFS_POSIX_ACL = yes;
    PROC_FS = yes;
    SYSFS = yes;
    DEVTMPFS = yes;
    DEVTMPFS_MOUNT = yes;
    OVERLAY_FS = yes; # Nix build sandbox
    FUSE_FS = yes;

    # console / tty
    TTY = yes;
    SERIAL_8250 = yes;
    SERIAL_8250_CONSOLE = yes;
    PRINTK = yes;

    # networking core (SSH in, offline builds)
    NET = yes;
    INET = yes;
    UNIX = yes;
    PACKET = yes;
    NETDEVICES = yes;

    # process / exec / namespaces (Nix builds need user + mount + pid + net ns)
    BINFMT_ELF = yes;
    MULTIUSER = yes;
    NAMESPACES = yes;
    USER_NS = yes;
    PID_NS = yes;
    NET_NS = yes;
    UTS_NS = yes;
    IPC_NS = yes;
    CGROUPS = yes;
    SECCOMP = yes;
    EPOLL = yes;
    SIGNALFD = yes;
    TIMERFD = yes;
    EVENTFD = yes;
    FUTEX = yes;
    AIO = yes;

    # copyfail surface: splice/pipe paths must be present
    # (pipe/splice are core and not separately configurable; kept as a note).
    #
    # The copyfail primitive drives the page-cache mutation through an AF_ALG
    # `aead` socket bound to `authencesn(hmac(sha256),cbc(aes))`. Without the
    # AF_ALG userspace crypto interface and that template's building blocks,
    # `socket(AF_ALG)` fails with EAFNOSUPPORT, the exploit's patch_chunk() is a
    # no-op, and umount is never corrupted. Build the whole chain in.
    CRYPTO = yes;
    CRYPTO_USER_API = yes;
    CRYPTO_USER_API_HASH = yes;
    CRYPTO_USER_API_SKCIPHER = yes;
    CRYPTO_USER_API_AEAD = yes;
    CRYPTO_AEAD = yes;
    CRYPTO_AUTHENC = yes; # provides authenc / authencesn templates
    CRYPTO_HMAC = yes;
    CRYPTO_SHA256 = yes;
    CRYPTO_CBC = yes;
    CRYPTO_AES = yes;
    CRYPTO_MANAGER = yes;

    # boot
    BLK_DEV_INITRD = yes;
    RD_GZIP = yes;
    RD_XZ = yes;
    EFI = yes;
    EFI_STUB = yes;
  };

  # dirtyfrag needs two extra kernel surfaces on top of slimConfig; kept out of
  # the shared config so the copyfail (6.18.21) derivation is byte-identical and
  # doesn't rebuild. See the `dirtyfrag` entry below for the CVE mapping.
  dirtyfragConfig = {
    # xfrm-ESP (CVE-2026-43284): the exploit opens NETLINK_XFRM and installs an
    # IPPROTO_ESP transport SA (hmac(sha256)/cbc(aes), UDP-encap, ESN), then
    # drives the in-place scatterlist write via vmsplice/splice. The auth/crypt
    # algs it names are already in slimConfig's crypto block.
    XFRM = yes;
    XFRM_USER = yes;
    INET_ESP = yes; # esp4

    # rxrpc/rxkad (CVE-2026-43500): AF_RXRPC socket with the rxkad security
    # class, whose token uses pcbc(fcrypt) (also exercised via AF_ALG).
    AF_RXRPC = yes;
    RXKAD = yes;
    KEYS = yes;
    CRYPTO_PCBC = yes;
    CRYPTO_FCRYPT = yes;
  };

  # fragnesia (CVE-2026-46300) is a SEPARATE, later bug in the same ESP/XFRM
  # surface as dirtyfrag, but over ESP-in-TCP (espintcp) rather than ESP-in-UDP.
  # It transitions a TCP socket to espintcp ULP after file pages are spliced into
  # the receive queue, then the kernel processes them as ESP ciphertext and XORs
  # an AES-GCM keystream byte into the cached page — arbitrary page-cache byte
  # writes, no race. Needs, on top of the dirtyfrag surface: TCP-ULP espintcp,
  # rfc4106(gcm(aes)) for the ESP AEAD, and ecb(aes) (via AF_ALG) to build the
  # keystream lookup table.
  fragnesiaConfig = dirtyfragConfig // {
    XFRM_ESPINTCP = yes; # ESP-in-TCP ULP (TCP_ENCAP_ESPINTCP)
    CRYPTO_GCM = yes; # provides gcm(aes) / rfc4106(gcm(aes))
    CRYPTO_GHASH = yes; # gcm dependency
    CRYPTO_ECB = yes; # ecb(aes) via AF_ALG for the keystream table
  };

  # dirtydecrypt / DirtyCBC (rxgk page-cache write, missing COW guard in
  # rxgk_decrypt_skb). Same family, but abuses AF_RXRPC's rxgk (GSSAPI/Kerberos)
  # security class: a spliced rxgk packet on loopback gets decrypted in-place
  # into the shared pagecache folio. Needs RXGK on top of the dirtyfrag rxrpc
  # surface; RXGK's Kconfig `select`s CRYPTO_KRB5 + all the enctype crypto
  # (aes/cts/cmac/camellia/sha), so we don't have to list them.
  dirtydecryptConfig = dirtyfragConfig // {
    RXGK = yes; # RxRPC GSSAPI (rxgk) security
  };

  # pintheft: an RDS zerocopy double-free (rds_message_zcopy_from_user drops
  # already-pinned pages on the error path, then RDS cleanup frees them again)
  # turned into a page-cache OVERWRITE via io_uring fixed buffers. Unlike the
  # rxgk/xfrm family this is a controlled write (IORING_OP_READ_FIXED copies the
  # exact payload into the reclaimed page-cache page). Needs the RDS transport
  # (RDS + RDS_TCP; the zcopy path checks t_type == RDS_TRANS_TCP) and io_uring.
  pintheftConfig = {
    RDS = yes;
    RDS_TCP = yes;
    IO_URING = yes;
  };

  mkVuln =
    {
      version,
      hash,
      extraConfig ? { },
    }:
    pkgs.linuxPackagesFor (
      pkgs.linux_6_18.override {
        argsOverride = {
          inherit version;
          modDirVersion = version;
          src = pkgs.fetchurl {
            url = "mirror://kernel/linux/kernel/v6.x/linux-${version}.tar.xz";
            inherit hash;
          };
          autoModules = false;
          # A slim, hand-picked structuredExtraConfig leaves many options from
          # nixpkgs' common-config with unmet dependencies (their parents are
          # off). On x86_64 the kernel builder treats those as fatal "unused
          # option" errors by default; ignore them (as linux-rpi.nix does) so
          # the from-source build succeeds with only the options we enabled.
          ignoreConfigErrors = true;
          structuredExtraConfig = slimConfig // extraConfig;
        };
      }
    );
in
{
  # copyfail (CVE-2026-31431): the algif_aead in-place page-cache mutation
  # primitive. Fixed upstream by a664bf3d603d ("crypto: algif_aead - Revert to
  # operating out-of-place"), backported to linux-6.18.y in 6.18.22. The LAST
  # vulnerable 6.18.y point release is therefore 6.18.21 — 6.18.22+ (including
  # 6.18.28) run the AF_ALG primitive without error but the in-place write is a
  # no-op, so the exploit reports "patched". Pin 6.18.21.
  copyfail = mkVuln {
    version = "6.18.21";
    hash = "sha256-HDghT7E3uuhbgrglN7WYc1hiG5Fasqjk8J5gaXwZR08=";
  };

  # dirtyfrag = CVE-2026-43284 (xfrm-ESP) + CVE-2026-43500 (rxrpc/rxkad), two
  # in-place scatterlist page-cache corruptions. The rxrpc bug survives through
  # 6.18.28 (fixed 6.18.29), but the xfrm-ESP bug — the one that corrupts the
  # setuid umount, the clean copyfail-style vector we use — is fixed one release
  # earlier, in 6.18.28. So the LAST release vulnerable to the umount vector is
  # 6.18.27 (verified: on 6.18.28 the ESP write reports "target unchanged").
  # 6.18.27 is still copyfail-patched (>= 6.18.22): copyfail is a no-op here,
  # dirtyfrag is not — the whole point of the level-2 challenge. Needs the
  # xfrm/rxrpc surfaces in dirtyfragConfig on top of the shared slim config.
  dirtyfrag = mkVuln {
    version = "6.18.27";
    hash = "sha256-JQF7k5RvC6LL9xkQtZZAop2RZ6W2XM1BsSzZkYdc4uo=";
    extraConfig = dirtyfragConfig;
  };

  # fragnesia (CVE-2026-46300): the espintcp page-cache write. Its ESP-in-TCP fix
  # lands later than dirtyfrag's, so 6.18.28 — the kernel nixpkgs rev
  # da5ad661ba4e5ef59ba743f0d112cbc30e474f32 shipped — is still fragnesia-
  # vulnerable while being copyfail-patched (6.18.22) and dirtyfrag-umount-patched
  # (xfrm-ESP fixed 6.18.28). Used by the level-3 remote-builder challenge, whose
  # exploit corrupts sshd-session rather than a setuid binary.
  fragnesia = mkVuln {
    version = "6.18.28";
    hash = "sha256-82B4lINYbPiiC0qyv/526ta2LA2x7rDZFylEVsTXe3Q=";
    extraConfig = fragnesiaConfig;
  };

  # dirtydecrypt / DirtyCBC = CVE-2026-31635 (rxgk COW-guard, missing COW in
  # rxgk_decrypt_skb). Introduced in 6.16, fixed in 6.18.23 (beee051f259a), so
  # the LAST vulnerable release is 6.18.22 (verified: on 6.18.32 the rxgk write
  # no-ops — byte 1/96 fails). Its write LANDS on 6.18.22 but the PoC can't
  # value-steer the bytes here (garbles rather than placing a clean payload), so
  # level 4 uses pintheft (below) instead; kept for the documented rxgk finding.
  dirtydecrypt = mkVuln {
    version = "6.18.22";
    hash = "sha256-ojyS+vNlc4XCxrX07dj4G4CJB+vmA/owaZ6uIk2lX1k=";
    extraConfig = dirtydecryptConfig;
  };

  # pintheft (RDS zerocopy double-free -> io_uring page-cache overwrite; patch
  # netdev 2026-05-05). Its CONTROLLED write (IORING_OP_READ_FIXED copies the
  # exact payload into the reclaimed page-cache page) makes it the level-4
  # exploit — reliable clean root on the first run. Pinned to 6.18.32, which is:
  #   - the kernel nixpkgs rev erinyes ships (the real stack the CTF stands up),
  #   - the LAST pintheft-vulnerable release (fixed in 6.18.33), and
  #   - patched for every earlier bug (copyfail/dirtyfrag/fragnesia/dirtydecrypt),
  # so pintheft is the ONLY thing that works here — a clean level-4 design. Needs
  # the RDS + io_uring surface, not rxgk. Used by the level-4 Hydra
  # remote-builder challenge (no sshd; the payload lands on a system-executed
  # root binary — can oops the kernel afterward, fine since root already ran).
  pintheft = mkVuln {
    version = "6.18.32";
    hash = "sha256-Bn2t1EVXgoTqYVjzEveXDYlA/tPglNvknP9m0YjTvaQ=";
    extraConfig = pintheftConfig;
  };
}
