{
  lib,
  jq,
  nodejs_24,
  pydd,
  runCommand,
}:
let
  # Impure by request: no `rev`, so every impure evaluation (`ai-rebuild`,
  # `nix build --file .`) resolves `main` fresh and the next rebuild builds
  # whatever landed upstream. pydd reads the lock of that revision in the
  # build, so no dependency hash needs a bump.
  upstream = builtins.fetchTree {
    type = "github";
    owner = "pingdotgg";
    repo = "t3code";
    ref = "main";
  };

  # The web build writes license notices from SPDX templates, and downloads
  # each missing one into `.generated/`. The sandbox has no network, so the
  # cache is filled here, at the revision and version that the tree pins.
  licenses = builtins.readFile "${upstream}/scripts/lib/third-party-licenses.ts";
  constant =
    name:
    let
      found = builtins.match ''.*const ${name} = "([^"]+)";.*'' licenses;
    in
    if found == null then
      throw "t3code: scripts/lib/third-party-licenses.ts no longer defines ${name}."
    else
      builtins.head found;
  spdx = builtins.fetchTree {
    type = "github";
    owner = "spdx";
    repo = "license-list-data";
    rev = constant "SPDX_LICENSE_LIST_REVISION";
  };
  spdxCache = ".generated/third-party-licenses/spdx/${constant "SPDX_LICENSE_LIST_VERSION"}";
in
pydd.node.npm {
  # The server builds through vite-plus's task runner, which no script of
  # package.json names on its own. The root runs `npm run`, so add one.
  project = runCommand "t3code-source-${upstream.shortRev}" { nativeBuildInputs = [ jq ]; } ''
    cp -r ${upstream} $out
    chmod -R u+w $out
    jq '.scripts["build:t3"] = "vp run --filter t3 build"' ${upstream}/package.json > $out/package.json
    mkdir -p $out/${lib.dirOf spdxCache}
    cp -r ${spdx}/json/details $out/${spdxCache}
  '';
  name = "t3code";
  program = "t3";
  nodejs = nodejs_24;
  # The server and what it links to: the web client it bundles, and the
  # shared packages. Desktop and mobile stay out. The server's build script
  # imports `scripts/lib` by relative path, not as a workspace link, so
  # that member is named too.
  members = [
    "apps/server"
    "scripts"
  ];
  scripts = [ "build:t3" ];
  # apps/web depends on @clerk/electron, whose peer electron downloads its
  # binary at install. The server never runs electron.
  overrides.electron.env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
}
