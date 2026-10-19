{
  fetchFromGitHub,
  pydd,
}:
let
  src = fetchFromGitHub {
    owner = "Timpan4";
    repo = "kubecove";
    tag = "app-v0.12.5";
    hash = "sha256-8Ss34Ie/19LgK5+wyEU7W3oFVQzLUq33iSrVANamcP4=";
  };
  frontend =
    runtime:
    pydd.node.npm {
      project = src;
      scriptEnv.KUBECOVE_PUBLIC_RUNTIME = runtime;
    };
  web = frontend "web";
  native = frontend "native";
in
{
  inherit web native;
  desktop = pydd.rust.cargo {
    root = src;
    project = "${src}/src-tauri";
    # tauri-build reads `frontendDist = "../dist"` from tauri.conf.json.
    files.dist = "${native}/lib/node_modules/kubecove/dist";
  };
  server = pydd.rust.cargo {
    root = src;
    project = "${src}/src-tauri/server";
    # rust-embed reads `../../dist/` from the server crate at compile time.
    files.dist = "${web}/lib/node_modules/kubecove/dist";
  };
}
