{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optional
    optionalAttrs
    optionalString
    optionals
    types
    ;

  cfg = config.services.ctf-server;
  flakePackages = self.packages.${pkgs.system} or { };

  databaseUrlPort = optionalString (cfg.database.port != null) ":${toString cfg.database.port}";
  databaseUrlSocket = optionalString (
    cfg.database.socketDir != null
  ) "?socket_dir=${cfg.database.socketDir}";
  databaseUrl = "postgresql://${cfg.database.user}@${cfg.database.host}${databaseUrlPort}/${cfg.database.name}${databaseUrlSocket}";

  generatedSecretKeyBaseFile = "${cfg.secretsDir}/secret-key-base";
  generatedReleaseCookieFile = "${cfg.secretsDir}/release-cookie";

  secretKeyBaseSource =
    if cfg.secretKeyBaseFile == null then
      generatedSecretKeyBaseFile
    else
      "$CREDENTIALS_DIRECTORY/secret-key-base";

  releaseCookieSource =
    if cfg.releaseCookieFile == null then
      generatedReleaseCookieFile
    else
      "$CREDENTIALS_DIRECTORY/release-cookie";

  vmPortRange = "${toString cfg.vmPortRange.from}..${toString cfg.vmPortRange.to}";

  exportSecretKeyBase = ''
    export SECRET_KEY_BASE="$(tr -d '\n' < "${secretKeyBaseSource}")"
  '';

  exportReleaseCookie = ''
    export RELEASE_COOKIE="$(tr -d '\n' < "${releaseCookieSource}")"
  '';

  exportDatabaseUrl =
    if cfg.database.createLocally then
      ''
        export DATABASE_URL="${databaseUrl}"
      ''
    else
      ''
        export DATABASE_URL="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/database-url")"
      '';
in
{
  imports = [ ./ctf-libvirt.nix ];

  options.services.ctf-server = {
    enable = mkEnableOption "the NixVegas CTF server";

    package = mkOption {
      type = types.package;
      default = flakePackages.ctf-server;
      defaultText = "self.packages.\${pkgs.system}.ctf-server";
      description = "Package containing the CTF server release.";
    };

    vmBaseImagesPackage = mkOption {
      type = types.package;
      default = flakePackages.vm-bases;
      defaultText = "self.packages.\${pkgs.system}.vm-bases";
      description = "Package containing built challenge VM base qcow2 images.";
    };

    user = mkOption {
      type = types.str;
      default = "ctf-server";
      description = "User that runs the CTF server.";
    };

    group = mkOption {
      type = types.str;
      default = "ctf-server";
      description = "Group that runs the CTF server.";
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the service user and group.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/ctf-server";
      description = "State directory for the CTF server.";
    };

    secretsDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/secrets";
      description = "Directory for generated runtime secrets when explicit secret files are not configured.";
    };

    vmBaseImageDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/vm-bases";
      description = "Directory where challenge VM base images are exposed.";
    };

    vmOverlayDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/overlays";
      description = "Writable directory for per-attempt VM qcow2 overlays.";
    };

    host = mkOption {
      type = types.str;
      default = "localhost";
      description = "Host name used for generated public CTF web URLs.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "TCP port the CTF web endpoint listens on.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "::";
      description = "IP address, or localhost, that the CTF web endpoint listens on.";
    };

    urlScheme = mkOption {
      type = types.enum [
        "http"
        "https"
      ];
      default = "http";
      description = "Scheme used for generated public CTF web URLs.";
    };

    urlPort = mkOption {
      type = types.port;
      default = cfg.port;
      description = "Port used for generated public CTF web URLs.";
    };

    skipAccountConfirmation = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether newly registered teams are confirmed immediately without a
        confirmation email. Disabling this requires configuring a working
        mailer, otherwise registration fails after creating the account.
      '';
    };

    requireInviteCodes = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether a remote client must redeem a one-time invite code to register
        a team. Clients on a local network (see `localNetworks`) always register
        without a code, which prioritises in-person players. When false (the
        default) everyone registers freely. Generate codes with
        `mix ctf.gen_invites` or the /admin/invites panel. Enabling this needs
        `localNetworks` set, and the fronting proxy must pass the real client
        address in the X-Real-IP header (the app trusts that header only from a
        loopback proxy); otherwise every client is treated as remote.
      '';
    };

    localNetworks = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [
        "10.7.0.0/16"
        "10.8.0.0/16"
        "10.5.0.0/16"
      ];
      description = ''
        CIDR ranges that count as the local network for registration. A client
        whose real address falls in one of these registers without an invite
        code; every other client needs one when `requireInviteCodes` is true.
        The real address comes from the proxy's X-Real-IP header, trusted only
        from a loopback proxy. Malformed or out-of-range entries are dropped.
        Empty by default, so with no ranges set every client is treated as
        remote.
      '';
    };

    homeAssistantWebhookUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://ha.internal/api/webhook/ctf-flag-captured";
      description = ''
        Home Assistant webhook URL the backend POSTs to whenever a flag is
        captured (a small JSON body: event/team/group/level/score), so the space
        can react, e.g. flash the lights. Best-effort and unset by default: when
        null, no notification is sent and scoring is unaffected.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the HTTP port in the firewall.";
    };

    openVmFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open the challenge VM SSH forwarding port range.";
    };

    secretKeyBaseFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional file containing Phoenix SECRET_KEY_BASE. When unset, the
        module generates a persistent secret under secretsDir.
      '';
    };

    releaseCookieFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional file containing the BEAM release cookie. When unset, the
        module generates a persistent cookie under secretsDir.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional systemd EnvironmentFile for additional runtime settings.";
    };

    poolSize = mkOption {
      type = types.ints.positive;
      default = 10;
      description = "Ecto database connection pool size.";
    };

    ectoIpv6 = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable IPv6 socket options for Ecto.";
    };

    vmPortRange = {
      from = mkOption {
        type = types.port;
        default = 49152;
        description = "First host port used for challenge VM SSH forwarding.";
      };

      to = mkOption {
        type = types.port;
        default = 50175;
        description = "Last host port used for challenge VM SSH forwarding.";
      };
    };

    vmSshHost = mkOption {
      type = types.str;
      default = "localhost";
      description = "Host name shown to players for SSH access to challenge VMs.";
    };

    vmOverlaySize = mkOption {
      type = types.str;
      default = "20G";
      example = "40G";
      description = ''
        Virtual size of each per-attempt qcow2 overlay (a `qemu-img create`
        size string). The base images are small; overlays are created at this
        size and the guest grows its root fs to fill it at boot, giving each
        attempt real disk headroom for fetches/builds. qcow2 is thin, so this
        only consumes host disk as an attempt actually writes.
      '';
    };

    maxVmsPerTeam = mkOption {
      type = types.ints.unsigned;
      default = 8;
      description = ''
        Most running challenge VMs a single team may hold at once, guarding
        against a team exhausting host CPU/RAM. Counts attempts whose VM is up
        (provisioning/started); paused instances do not count and admin teams
        are exempt.
      '';
    };

    libvirtUri = mkOption {
      type = types.str;
      default = "qemu:///system";
      description = "Libvirt URI used for VM lifecycle operations.";
    };

    manageLibvirt = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable system libvirt for challenge VMs.";
    };

    egressAllowSubnets = mkOption {
      type = with types; listOf str;
      default = [ "10.4.2.0/24" ];
      example = [
        "10.4.2.0/24"
        "10.4.3.0/24"
      ];
      description = ''
        Destination CIDR subnets challenge VMs are permitted to reach.
        Everything else is dropped by the ctf-egress libvirt network filter.
        Defaults to the NixVegas cache/git subnet (cache.nixos.lv, git.nixos.lv).
      '';
    };

    egressInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ctf0";
      description = ''
        Host network interface that all challenge-VM egress is NAT'd out of
        (libvirt `<forward mode='nat' dev='...'>` on every per-attempt network).
        Guest traffic still follows the host routing table, so this must be the
        interface carrying the box's default route toward the CTF arena — set it
        to the CTF uplink so nothing leaks out a management/other interface.
        When null, libvirt masquerades out whatever interface the host default
        route uses, with no pinning.
      '';
    };

    runMigrations = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to run database migrations before starting the service.";
    };

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to create and use a local PostgreSQL database.";
      };

      name = mkOption {
        type = types.str;
        default = "ctf_server";
        description = "Local PostgreSQL database name.";
      };

      user = mkOption {
        type = types.str;
        default = "ctf-server";
        description = "Local PostgreSQL database user.";
      };

      host = mkOption {
        type = types.str;
        default = "localhost";
        description = ''
          Host component for the generated DATABASE_URL. When socketDir is set,
          this remains a syntactic URL host for Ecto while Postgrex connects
          through the configured Unix socket directory.
        '';
      };

      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Optional port for the generated DATABASE_URL.";
      };

      socketDir = mkOption {
        type = types.nullOr types.str;
        default = "/run/postgresql";
        description = ''
          Optional PostgreSQL Unix socket directory for the generated
          DATABASE_URL. Set to null to connect over TCP using database.host
          and database.port.
        '';
      };

      urlFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing DATABASE_URL when database.createLocally is false.";
      };
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables for the systemd service.";
    };
  };

  config = mkIf cfg.enable {
    warnings =
      optional (cfg.requireInviteCodes && cfg.localNetworks == [ ])
        "services.ctf-server.requireInviteCodes is enabled but localNetworks is empty, so every client is treated as remote and needs an invite code. Set localNetworks to your local ranges to let local players register freely.";

    assertions = [
      {
        assertion = cfg.database.createLocally || cfg.database.urlFile != null;
        message = "services.ctf-server.database.urlFile must be set when database.createLocally is false.";
      }
      {
        assertion = cfg.vmPortRange.from <= cfg.vmPortRange.to;
        message = "services.ctf-server.vmPortRange.from must be less than or equal to vmPortRange.to.";
      }
    ];

    users.groups = mkIf cfg.createUser {
      ${cfg.group} = { };
    };

    users.users = mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        extraGroups = optional cfg.manageLibvirt "libvirtd";
      };
    };

    # Libvirt networking (hook + nwfilters + libvirtd) lives in the shared
    # ctf-libvirt module so a dev machine can enable the same path.
    services.ctf-libvirt = mkIf cfg.manageLibvirt {
      enable = true;
      inherit (cfg) libvirtUri egressAllowSubnets openVmFirewall;
      vmPortRange = { inherit (cfg.vmPortRange) from to; };
    };

    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
        }
      ];
    };

    systemd.services.ctf-server-postgresql-ownership = mkIf cfg.database.createLocally {
      description = "NixVegas CTF server PostgreSQL ownership";
      requires = [ "postgresql-setup.service" ];
      after = [ "postgresql-setup.service" ];
      before = [ "ctf-server.service" ];
      path = [ config.services.postgresql.finalPackage ];

      script = ''
        psql -d postgres -v ON_ERROR_STOP=1 -tAc 'ALTER DATABASE "${cfg.database.name}" OWNER TO "${cfg.database.user}";'
      '';

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        RemainAfterExit = true;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.secretsDir} 0700 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.vmBaseImageDir} 0755 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.vmOverlayDir} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.port;

    systemd.services.ctf-server = {
      description = "NixVegas CTF server";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
      ]
      ++ optionals cfg.database.createLocally [ "ctf-server-postgresql-ownership.service" ]
      ++ optionals cfg.manageLibvirt [
        "libvirtd.service"
        "ctf-server-nwfilter.service"
      ];
      wants = optionals cfg.manageLibvirt [
        "libvirtd.service"
        "ctf-server-nwfilter.service"
      ];
      requires = optionals cfg.database.createLocally [ "ctf-server-postgresql-ownership.service" ];

      path = [
        pkgs.coreutils
        pkgs.findutils
      ];

      environment = {
        PHX_SERVER = "true";
        PHX_HOST = cfg.host;
        CTF_SERVER_LISTEN_IP = cfg.listenAddress;
        CTF_SERVER_LISTEN_PORT = toString cfg.port;
        CTF_SERVER_URL_SCHEME = cfg.urlScheme;
        CTF_SERVER_URL_PORT = toString cfg.urlPort;
        POOL_SIZE = toString cfg.poolSize;
        CTF_SERVER_VM_BASE_IMAGE_PATH = cfg.vmBaseImageDir;
        CTF_SERVER_VM_OVERLAY_PATH = cfg.vmOverlayDir;
        CTF_SERVER_VM_PORT_RANGE = vmPortRange;
        CTF_SERVER_MAX_VMS_PER_TEAM = toString cfg.maxVmsPerTeam;
        CTF_SERVER_VM_SSH_HOST = cfg.vmSshHost;
        CTF_SERVER_VM_LIBVIRT_URI = cfg.libvirtUri;
        CTF_SERVER_VM_OVERLAY_SIZE = cfg.vmOverlaySize;
        # The egress policy the login banner lists (kept in sync with the actual
        # ctf-libvirt nwfilters, which read the same values).
        CTF_SERVER_VM_EGRESS_ALLOW_SUBNETS = lib.concatStringsSep "," cfg.egressAllowSubnets;
        CTF_SERVER_VM_INTERNAL_ZONES = lib.concatStringsSep "," config.services.ctf-libvirt.internalZones;
        CTF_SERVER_SKIP_ACCOUNT_CONFIRMATION = if cfg.skipAccountConfirmation then "true" else "false";
        CTF_SERVER_REQUIRE_INVITE_CODES = if cfg.requireInviteCodes then "true" else "false";
        CTF_SERVER_LOCAL_NETWORKS = lib.concatStringsSep "," cfg.localNetworks;
      }
      // optionalAttrs cfg.ectoIpv6 { ECTO_IPV6 = "true"; }
      // optionalAttrs (cfg.egressInterface != null) {
        CTF_SERVER_VM_EGRESS_INTERFACE = cfg.egressInterface;
      }
      // optionalAttrs (cfg.homeAssistantWebhookUrl != null) {
        CTF_SERVER_HA_WEBHOOK_URL = cfg.homeAssistantWebhookUrl;
      }
      // cfg.extraEnvironment;

      preStart = ''
        set -euo pipefail

        find ${lib.escapeShellArg cfg.vmBaseImageDir} -maxdepth 1 -type l -name '*.qcow2' -delete

        for image in ${cfg.vmBaseImagesPackage}/*.qcow2; do
          ln -sfn "$image" ${lib.escapeShellArg cfg.vmBaseImageDir}/"$(basename "$image")"
        done

        ${optionalString (cfg.secretKeyBaseFile == null || cfg.releaseCookieFile == null) ''
          umask 077
          mkdir -p ${lib.escapeShellArg cfg.secretsDir}

          ${optionalString (cfg.secretKeyBaseFile == null) ''
            if [ ! -s ${lib.escapeShellArg generatedSecretKeyBaseFile} ]; then
              ${pkgs.coreutils}/bin/head -c 64 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w 0 > ${lib.escapeShellArg generatedSecretKeyBaseFile}
            fi
          ''}

          ${optionalString (cfg.releaseCookieFile == null) ''
            if [ ! -s ${lib.escapeShellArg generatedReleaseCookieFile} ]; then
              ${pkgs.coreutils}/bin/head -c 64 /dev/urandom | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1 > ${lib.escapeShellArg generatedReleaseCookieFile}
            fi
          ''}
        ''}

        ${optionalString cfg.runMigrations ''
          ${exportSecretKeyBase}
          ${exportReleaseCookie}
          ${exportDatabaseUrl}

          ${cfg.package}/bin/ctf_server eval "CtfServer.Release.migrate()"
        ''}
      '';

      script = ''
        set -euo pipefail

        ${exportSecretKeyBase}
        ${exportReleaseCookie}
        ${exportDatabaseUrl}

        exec ${cfg.package}/bin/ctf_server start
      '';

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = "5s";
        LoadCredential =
          optional (cfg.secretKeyBaseFile != null) "secret-key-base:${cfg.secretKeyBaseFile}"
          ++ optional (cfg.releaseCookieFile != null) "release-cookie:${cfg.releaseCookieFile}"
          ++ optional (!cfg.database.createLocally) "database-url:${cfg.database.urlFile}";
      }
      // optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
