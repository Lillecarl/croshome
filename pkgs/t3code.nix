{
  lib,
  stdenv,
  nodejs_24,
  pnpm,
  git,
  cacert,
  python3,
  gnumake,
  gcc,
  makeWrapper,
}:
let
  # Impure by request: no `rev`, so every impure evaluation (`ai-rebuild`,
  # `nix build --file .`) resolves `main` fresh and the next rebuild builds
  # whatever landed upstream -- `git pull` semantics without a local clone.
  # Pure evaluation cannot resolve this and fails here, at the source,
  # rather than deeper in the build. This repository already builds impurely
  # (`builtins.currentSystem` in ../default.nix), so nothing new is assumed.
  src = builtins.fetchTree {
    type = "github";
    owner = "pingdotgg";
    repo = "t3code";
    ref = "main";
  };
in
stdenv.mkDerivation {
  pname = "t3code";
  version = "main-${src.shortRev}";
  inherit src;

  # The build fetches from the npm registry and GitHub at build time, which
  # a sandboxed build forbids. Same shape as ./openclaw.nix: impure source
  # in, network during the build, self-contained tree out.
  __noChroot = true;

  nativeBuildInputs = [
    nodejs_24
    pnpm
    git
    cacert
    # node-pty's build scripts fall back to compiling when no prebuild
    # matches; give them the toolchain rather than hoping.
    python3
    gnumake
    gcc
    makeWrapper
  ];

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # The store copy is read-only and pnpm/vp write node_modules, dist and
    # lockfile state beside the sources, so build in a writable copy.
    cp -r "$src" ./t3code-src
    chmod -R u+w ./t3code-src
    cd ./t3code-src

    # Keep every tool cache inside the build: nothing may reach the real
    # HOME, and nothing written here survives the build.
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export XDG_DATA_HOME=$TMPDIR/.local/share
    export XDG_CONFIG_HOME=$TMPDIR/.config
    export npm_config_cache=$TMPDIR/npm-cache
    export NPM_CONFIG_CACHE=$TMPDIR/npm-cache
    export NODE_EXTRA_CA_CERTS=${cacert}/etc/ssl/certs/ca-bundle.crt
    export GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    mkdir -p "$npm_config_cache"

    # vite-plus orchestrates install and build upstream (`vp i`,
    # `vp run ...`). Its version moves with the repo (0.3.3 -> 1.0.0 in a
    # day), so read the workspace catalog rather than pinning: a pinned
    # global against a newer tree fails with "Expected
    # @voidzero-dev/vite-plus-core@X, but found @Y".
    VP_VERSION=$(sed -n 's/^  vite-plus: //p' pnpm-workspace.yaml | head -n 1 | tr -d "\"[:space:]\"")
    if [ -z "$VP_VERSION" ]; then
      echo "t3code: could not read vite-plus version from pnpm-workspace.yaml" >&2
      exit 1
    fi
    echo "t3code: installing vite-plus@$VP_VERSION to match the source tree"
    export NPM_CONFIG_PREFIX=$TMPDIR/vp-prefix
    npm install -g "vite-plus@$VP_VERSION"
    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

    # Server workspace only (`t3` is apps/server): its build depends on the
    # web workspace build and bundles that client into dist/client, so no
    # desktop, electron or mobile workspace ever builds here.
    vp i
    vp run --filter t3 build

    cd ..
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # A self-contained production tree for the server workspace: dist/ (the
    # bundled CLI plus the web client it serves) beside the production
    # node_modules the bundle keeps external at runtime (node-pty, keyring
    # helpers, ...). Verified 2026-10-12: 301M, runs with only Node beside it.
    cd ./t3code-src
    pnpm --filter t3 deploy "$out/share/t3code" --prod --legacy

    # `deploy --legacy` links the deployed workspace package back to the
    # build tree (`node_modules/.pnpm/node_modules/t3 -> .../t3code-src/...`),
    # which is gone after the build. Nothing at runtime resolves the
    # package by its own workspace name -- the CLI is bundled -- so drop
    # the link rather than shipping a dangling one.
    rm -f "$out/share/t3code/node_modules/.pnpm/node_modules/t3"

    mkdir -p $out/bin
    makeWrapper ${lib.getExe nodejs_24} $out/bin/t3 \
      --add-flags "$out/share/t3code/dist/bin.mjs"

    runHook postInstall
  '';

  meta = with lib; {
    description = "T3 Code server (headless), built from latest main";
    homepage = "https://github.com/pingdotgg/t3code";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "t3";
  };
}
