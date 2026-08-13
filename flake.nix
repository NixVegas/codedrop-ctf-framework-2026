{
  description = "CTF server flake.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.hydra = {
    url = "github:NixOS/hydra/hydra.nixos.org";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      # --- System-independent challenge discovery ----------------------
      # A challenge lives in priv/challenges/<name>/ and is baked into one or
      # more qcow2 images using the *pinned* nixpkgs (reproducible, no impure
      # channel lookup at build time). Single-VM challenges ship a vm.nix baked
      # into one image. Cluster challenges ship a nodes/ dir: each
      # nodes/<role>.nix (which imports the challenge's own vm.nix base) is
      # baked into its own image, and the top-level vm.nix is a base module
      # only, never built directly.
      challengesDir = ./priv/challenges;

      # Split a `{group_underscored}_{level}` dir name into its runtime parts.
      groupLevel =
        name:
        let
          parts = nixpkgs.lib.splitString "_" name;
        in
        {
          group = nixpkgs.lib.concatStringsSep "-" (nixpkgs.lib.init parts);
          level = nixpkgs.lib.last parts;
        };

      # Role files (basename sans .nix) under a challenge's nodes/ dir, or []
      # for a single-VM challenge.
      nodeRoles =
        name:
        let
          nodesDir = challengesDir + "/${name}/nodes";
        in
        if builtins.pathExists nodesDir then
          map (nixpkgs.lib.removeSuffix ".nix") (
            builtins.attrNames (
              nixpkgs.lib.filterAttrs (f: t: t == "regular" && nixpkgs.lib.hasSuffix ".nix" f) (
                builtins.readDir nodesDir
              )
            )
          )
        else
          [ ];

      # Every challenge dir that ships a vm.nix (single-VM) or a nodes/ dir.
      challengeDirs = builtins.attrNames (
        nixpkgs.lib.filterAttrs (
          name: type:
          type == "directory"
          && (
            builtins.pathExists (challengesDir + "/${name}/vm.nix")
            || builtins.pathExists (challengesDir + "/${name}/nodes")
          )
        ) (builtins.readDir challengesDir)
      );

      # Flat list of images to build. Each unit carries a unique `key` (its
      # packages.<system>.<key> attr and diskSize lookup), the NixOS
      # `configFile` to bake, and the `outputNames` it is symlinked to in the
      # aggregate: the intern `<dir>[_<role>].qcow2` plus the runtime
      # `<group>_<level>[_<role>].qcow2` the provisioner expects.
      imageUnits = nixpkgs.lib.concatMap (
        name:
        let
          gl = groupLevel name;
          roles = nodeRoles name;
        in
        if roles == [ ] then
          [
            {
              key = name;
              configFile = challengesDir + "/${name}/vm.nix";
              outputNames = nixpkgs.lib.unique [
                "${name}.qcow2"
                "${gl.group}_${gl.level}.qcow2"
              ];
            }
          ]
        else
          map (role: {
            key = "${name}_${role}";
            configFile = challengesDir + "/${name}/nodes/${role}.nix";
            outputNames = nixpkgs.lib.unique [
              "${name}_${role}.qcow2"
              "${gl.group}_${gl.level}_${role}.qcow2"
            ];
          }) roles
      ) challengeDirs;

      # --- Per-system derivations --------------------------------------
      perSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };
          beamPkgs = with pkgs.beam; packagesWith interpreters.erlang_28;
          extraErlangDeps = with pkgs; [
            wxwidgets_3_2
            libpng
            libGLU
            libGL
          ];

          # The prebuilt libguestfs appliance is x86_64/i686-only. On other
          # hosts (e.g. aarch64 dev boxes) fall back to plain libguestfs,
          # which builds its appliance via supermin at runtime.
          guestfs =
            if pkgs.stdenv.hostPlatform.isx86_64 then pkgs.libguestfs-with-appliance else pkgs.libguestfs;

          mkVmBase =
            unit:
            let
              eval = import (nixpkgs + "/nixos") {
                inherit system;
                configuration = unit.configFile;
                # Expose extra flake inputs to challenge node configs. The level-4
                # Hydra cluster imports `hydra.nixosModules.*`; harmless for the
                # challenges that don't reference it.
                specialArgs = { inherit (self.inputs) hydra; };
              };
              # Image units whose baked closure does not fit the 4 GiB default
              # (e.g. one carrying a compiler toolchain). Add a unit's `key` here
              # if its build runs out of space; none of the shipped challenges
              # currently need it.
              largeImageKeys = [ ];
              diskSize = if builtins.elem unit.key largeImageKeys then 8192 else 4096;
            in
            import (nixpkgs + "/nixos/lib/make-disk-image.nix") {
              inherit pkgs;
              inherit (pkgs) lib;
              inherit (eval) config;
              configFile = unit.configFile;
              inherit diskSize;
              format = "qcow2";
              installBootLoader = true;
              partitionTableType = if pkgs.stdenv.hostPlatform.isAarch64 then "efi" else "legacy";
            };

          # One derivation per image unit, e.g. packages.<system>.basic_nix_1
          # or packages.<system>.capture_the_poll_1_web.
          vmBaseImages = builtins.listToAttrs (
            map (unit: {
              name = unit.key;
              value = mkVmBase unit;
            }) imageUnits
          );
          ctfServerPackage = pkgs.callPackage ./nix/package.nix {
            beamPackages = beamPkgs;
            inherit guestfs;
          };

          # Aggregate: gathers every image under one out path, symlinked to all
          # of its output names. Building this lets Nix evaluate & build every
          # image in a single invocation, sharing and deduping their closures.
          vmBasesAll = pkgs.runCommand "ctf-vm-bases" { } (
            ''
              mkdir -p $out
            ''
            + nixpkgs.lib.concatMapStringsSep "\n" (
              unit:
              nixpkgs.lib.concatMapStringsSep "\n" (
                outputName: "ln -s ${vmBaseImages.${unit.key}}/nixos.qcow2 $out/${outputName}"
              ) unit.outputNames
            ) imageUnits
          );
        in
        {
          inherit
            pkgs
            beamPkgs
            extraErlangDeps
            guestfs
            vmBaseImages
            ctfServerPackage
            vmBasesAll
            ;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          s = perSystem system;
        in
        s.vmBaseImages
        // {
          ctf-server = s.ctfServerPackage;
          default = s.ctfServerPackage;
          vm-bases = s.vmBasesAll;
        }
      );

      nixosModules.ctf-server = import ./nix/module.nix { inherit self; };
      nixosModules.default = self.nixosModules.ctf-server;

      # Just the libvirt networking (qemu hook + egress nwfilters), split out of
      # the full server module.
      nixosModules.ctf-libvirt = ./nix/ctf-libvirt.nix;

      # Convenience for a dev machine: enables the same libvirt networking the
      # production server uses, so challenge VMs (single-VM and clusters, with
      # hub-mode capture) come up on the real per-attempt bridge under
      # `mix phx.server`. Add your user to the "libvirtd" group. See HACKING.md.
      nixosModules.ctf-dev =
        { ... }:
        {
          imports = [ ./nix/ctf-libvirt.nix ];
          services.ctf-libvirt.enable = true;
          # Dev hands out `ssh -p <port> ctf@localhost`. The hook's
          # OUTPUT-chain DNAT matches that connection, but the packet keeps
          # its 127.0.0.1 source address, and the kernel drops
          # loopback-sourced packets leaving a real interface as martians
          # unless route_localnet is set. Dev-only on purpose: players reach
          # the event host over the network (PREROUTING path), which needs
          # no localnet routing, so prod keeps the hardening default.
          boot.kernel.sysctl."net.ipv4.conf.all.route_localnet" = 1;
        };

      # `nix fmt` formats the whole tree. nixfmt-tree is a treefmt wrapper
      # around the same nixfmt the pre-commit hook uses; unlike bare nixfmt it
      # traverses directories and needs no path args (bare nixfmt would read
      # stdin and hang on `nix fmt`).
      formatter = forAllSystems (system: (perSystem system).pkgs.nixfmt-tree);

      # The challenge-VM integration test provisions real VMs via guestfish,
      # whose libguestfs appliance is x86_64-only in nixpkgs. VM provisioning
      # (and this test) is therefore x86_64-only; aarch64 gets the dev shell
      # and base-image builds but not full VM provisioning.
      checks."x86_64-linux" =
        let
          s = perSystem "x86_64-linux";
        in
        {
          ctf-server-challenge-vm = s.pkgs.callPackage ./nixos/tests/ctf-server-challenge-vm.nix {
            inherit self;
          };

          # capture-the-poll/1 solvability: the multi-node cluster stands up and
          # the intended solve reaches the flag end to end.
          ctf-server-capture-the-poll = s.pkgs.callPackage ./nixos/tests/ctf-server-capture-the-poll.nix {
            inherit self;
          };

          # Shared offline help tooling: `tldr <cmd>` renders baked pages, no nag.
          challenge-help = s.pkgs.callPackage ./nixos/tests/challenge-help.nix {
            inherit self;
          };
        };

      devShells = forAllSystems (
        system:
        let
          s = perSystem system;
        in
        {
          default = s.pkgs.mkShell {
            buildInputs = [
              s.beamPkgs.erlang
              s.beamPkgs.elixir_1_19

              s.beamPkgs.hex

              s.pkgs.inotify-tools
              s.pkgs.nodejs
              s.pkgs.postgresql
              s.pkgs.tailwindcss_3
              s.pkgs.esbuild
              s.pkgs.watchman

              # Formatting (used by the shared .githooks/pre-commit hook).
              s.pkgs.nixfmt

              # VM tooling
              s.pkgs.qemu
              s.guestfs
              s.pkgs.libvirt
              s.pkgs.virt-manager
            ]
            ++ s.extraErlangDeps; # Add GUI deps at runtime instead of rebuild

            ERL_INCLUDE_PATH = "${s.beamPkgs.erlang}/lib/erlang/usr/include";
            ERL_AFLAGS = "-kernel shell_history enabled";

            # Make GUI libraries available at runtime
            LD_LIBRARY_PATH = s.pkgs.lib.makeLibraryPath s.extraErlangDeps;

            shellHook = ''
              # Use the repo's shared git hooks (nixfmt pre-commit check).
              if git rev-parse --git-dir >/dev/null 2>&1; then
                git config --local core.hooksPath .githooks
              fi

              # Allow mix to work on local directory
              mkdir -p .nix-mix
              mkdir -p .nix-hex
              export MIX_HOME=$PWD/.nix-mix
              export HEX_HOME=$PWD/.nix-hex
              export ERL_LIBS=$HEX_HOME/lib/erlang/lib

              # Concat paths
              export PATH=$MIX_HOME/bin:$PATH
              export PATH=$MIX_HOME/escripts:$PATH
              export PATH=$HEX_HOME/bin:$PATH

              # Asset pipeline stuff
              export MIX_TAILWIND_PATH="$(which tailwindcss)"
              export MIX_TAILWIND_VERSION="$(tailwindcss --help | awk 'NR==2 {print substr($2,2)}')"
              export MIX_ESBUILD_PATH="$(which esbuild)"
              export MIX_ESBUILD_VERSION="$(esbuild --version)"

              # PostgreSQL setup
              export PGDATA=$PWD/.nix-postgres
              export PGHOST=$PWD/.nix-postgres
              export LOG_PATH=$PWD/.nix-postgres/LOG
              export PGDATABASE=ctf_dev
              export PGUSER=postgres
              export PGPASSWORD=postgres
              export DATABASE_URL="postgresql://postgres:postgres@/ctf_dev?host=$PGDATA"

              if [ ! -d $PGDATA ]; then
                echo "Initializing PostgreSQL database..."
                initdb $PGDATA --auth=md5 --username=postgres --pwfile=<(echo "postgres") >/dev/null
                echo "unix_socket_directories = '$PGDATA'" >> $PGDATA/postgresql.conf
                echo "listen_addresses = '''" >> $PGDATA/postgresql.conf
              fi

              # Start PostgreSQL if not running
              if ! pg_ctl status -D $PGDATA >/dev/null 2>&1; then
                echo "Starting PostgreSQL..."
                pg_ctl start -D $PGDATA -l $LOG_PATH >/dev/null
                sleep 2
                createdb $PGDATABASE 2>/dev/null || true
              fi

              # "Run: `mix archive.install hex phx_new` for phoenix."
              mix do local.rebar --force + local.hex --force
              if ! mix archive | grep -q "phx_new"; then
                echo "Installing Phoenix generator..."
                mix archive.install hex phx_new --force
              fi

              echo "PostgreSQL is running. Database: $PGDATABASE"
              echo "To stop PostgreSQL: pg_ctl stop -D $PGDATA"

              export PS1="$(echo $PS1) 🏴‍☠️ ctf-server $ "
            '';

            shellExitHook = ''
              if [ -d $PGDATA ]; then
                pg_ctl stop -D $PGDATA >/dev/null 2>&1 || true
              fi
            '';
          };
        }
      );
    };
}
