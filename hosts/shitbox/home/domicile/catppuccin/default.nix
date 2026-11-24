# Catppuccin's userstyles as an extension, instead of Stylus: Stylus keeps its
# styles in the browser profile, where each would be imported by hand.
{
  lib,
  fetchFromGitHub,
  fetchurl,
  lessc,
  linkFarm,
  python3,
  runCommand,
  flavor,
  accent,
}:
let
  userstyles = fetchFromGitHub {
    owner = "catppuccin";
    repo = "userstyles";
    rev = "1675770ba72e34ae31fdfbebbfac8a9b888414c2";
    hash = "sha256-BJQ2/73rJQV1UQw//LBEZEdTXC5ve4VzH0s4z3sPBpE=";
  };

  # What the styles import. The builder fails on one missing here.
  remote = {
    "https://catppuccin.github.io/gitea/theme-catppuccin-${flavor}-${accent}.css" =
      "sha256-YfEvAyiGXKp7XHTAPycDEu7Pw2inkzlsPKoFjYUUBCE=";
    "https://chroma.catppuccin.com/${flavor}-chroma-style.css" =
      "sha256-UB3qSqdklEkwpr1OzRnloEkiiuLyGHFqVE8pqUlGDUE=";
    "https://prismjs.catppuccin.com/variables.important.css" =
      "sha256-YuheYDpqJ/FfPOxPdD+XioxyVGqlmkrPip7d6THoUrc=";
    "https://python.catppuccin.com/pygments/catppuccin-variables.important.css" =
      "sha256-XVji5jYxl8Cj6zqhHX/249O7x0pQh9/1ZDdNNO/IKws=";
    "https://unpkg.com/@catppuccin/highlightjs@1.0.0/css/catppuccin-variables.css" =
      "sha256-Dw6A0CRpZrZ7Cc+lQiGoX406ZzlZCH4A/TVh7D+gXj4=";
    "https://unpkg.com/@catppuccin/highlightjs@1.0.0/css/catppuccin-variables.important.css" =
      "sha256-bj/nJEOBpOnecprel/lBXDY3bBu7EmgsjJJUW4bR1Ts=";
  };

  sheets = linkFarm "catppuccin-remote-css" (
    lib.mapAttrs' (url: hash: {
      name = builtins.hashString "sha256" url;
      value = fetchurl {
        inherit url hash;
        name = "catppuccin.css";
      };
    }) remote
  );
in
runCommand "catppuccin-userstyles-${flavor}-${accent}"
  {
    nativeBuildInputs = [
      lessc
      python3
    ];
  }
  ''
    python3 ${./build.py} ${userstyles} ${sheets} ${flavor} ${accent} ${
      lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./apply.js
          ./background.js
        ];
      }
    } $out
  ''
