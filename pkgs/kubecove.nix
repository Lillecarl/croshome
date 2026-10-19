{
  fetchFromGitHub,
  glib-networking,
  gsettings-desktop-schemas,
  gtk3,
  kubeconform,
  lib,
  librsvg,
  makeWrapper,
  pydd,
  webkitgtk_4_1,
  wrapGAppsHook3,
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
  # Upstream bundles kubeconform as a Tauri sidecar; this variable overrides it.
  kubeconformFlags = "--set-default KUBECOVE_KUBECONFORM ${lib.getExe kubeconform}";
in
{
  inherit web native;
  desktop =
    (pydd.rust.cargo {
      root = src;
      project = "${src}/src-tauri";
      # tauri-build reads `frontendDist = "../dist"` from tauri.conf.json.
      files.dist = "${native}/lib/node_modules/kubecove/dist";
      # `cargo tauri build` enables it; without it the app loads `devUrl`.
      features = [ "tauri/custom-protocol" ];
    }).overrideAttrs
      (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ wrapGAppsHook3 ];
        buildInputs = (old.buildInputs or [ ]) ++ [
          glib-networking
          gsettings-desktop-schemas
          gtk3
          librsvg
          webkitgtk_4_1
        ];
        preFixup = (old.preFixup or "") + ''
          gappsWrapperArgs+=(${kubeconformFlags})
        '';
      });
  server =
    (pydd.rust.cargo {
      root = src;
      project = "${src}/src-tauri/server";
      # rust-embed reads `../../dist/` from the server crate at compile time.
      files.dist = "${web}/lib/node_modules/kubecove/dist";
    }).overrideAttrs
      (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];
        postFixup = (old.postFixup or "") + ''
          for program in "$out"/bin/*; do
            wrapProgram "$program" ${kubeconformFlags}
          done
        '';
      });
}
