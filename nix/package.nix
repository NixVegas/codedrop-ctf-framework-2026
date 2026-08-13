{
  lib,
  beamPackages,
  esbuild,
  guestfs,
  libvirt,
  makeWrapper,
  openssh,
  qemu,
  tailwindcss_3,
}:

let
  pname = "ctf-server";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        name = baseNameOf path;
      in
      !(
        name == ".git"
        || name == "_build"
        || name == "deps"
        || name == ".nix-postgres"
        || name == "vm_bases"
        || name == "erl_crash.dump"
      );
  };

  elixir = beamPackages.elixir_1_19;
in
beamPackages.mixRelease {
  inherit
    pname
    version
    src
    elixir
    ;

  nativeBuildInputs = [
    esbuild
    makeWrapper
    tailwindcss_3
  ];

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit
      version
      src
      elixir
      ;
    hash = "sha256-1gU0e7e+4H8rr6yzrVjDhuzQ/Z1GN7TliOt/Ju8ramU=";
  };

  postBuild = ''
    (
      cd assets
      export NODE_PATH="$PWD/../deps"

      tailwindcss \
        --config=tailwind.config.js \
        --input=css/app.css \
        --output=../priv/static/assets/app.css \
        --minify

      # js/vega.js is a second entry point (the leaderboard's Vega runtime),
      # loaded on demand rather than bundled into app.js. The --alias flags
      # resolve Vega's UMD builds to the vendored copies under assets/vendor —
      # there is no npm install here, and this build runs in a sandbox. Keep
      # these arguments in sync with config/config.exs.
      esbuild js/app.js js/vega.js \
        --bundle \
        --target=es2017 \
        --outdir=../priv/static/assets \
        --external:/fonts/* \
        --external:/images/* \
        --alias:vega=./vendor/vega.min.js \
        --alias:vega-lite=./vendor/vega-lite.min.js \
        --alias:vega-embed=./vendor/vega-embed.min.js \
        --minify
    )

    ERL_LIBS="$PWD/_build/prod/lib" elixir -e '
      Application.put_env(:phoenix, :json_library, Jason)
      {:ok, _} = Application.ensure_all_started(:phoenix)
      :ok = Phoenix.Digester.compile("priv/static", "priv/static", true)
    '
  '';

  postInstall = ''
    wrapProgram $out/bin/ctf_server \
      --prefix PATH : ${
        lib.makeBinPath [
          guestfs
          libvirt
          openssh
          qemu
        ]
      }
  '';

  meta = {
    description = "NixVegas CTF server";
    homepage = "https://github.com/NixVegas/ctf-server";
    mainProgram = "ctf_server";
    platforms = lib.platforms.linux;
  };
}
