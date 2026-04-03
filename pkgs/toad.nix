{
  lib,
  buildPythonApplication,
  hatchling,
  textual,
  click,
  tree-sitter,
  httpx,
  platformdirs,
  rich,
  typeguard,
  xdg-base-dirs,
  textual-serve,
  textual-speedups,
  packaging,
  bashlex,
  pathspec,
  notify-py,
  pyperclip,
  watchdog,
  setproctitle,
  psutil,
  aiosqlite,
  fetchFromGitHub,
  fetchPypi,
}:
let
  specific = rec {
    hatchling' = hatchling.overridePythonAttrs (old: rec {
      version = "1.28.0";
      src = fetchPypi {
        pname = "hatchling";
        inherit version;
        hash = "sha256-TVCwKuzmiSuM0LPObILLIYWU0+xYNtvedb9BohqwBMg=";
      };
      doCheck = false;
    });

    platformdirs' = platformdirs.overridePythonAttrs (old: rec {
      version = "4.9.4";
      src = fetchPypi {
        pname = "platformdirs";
        inherit version;
        hash = "sha256-HsNWMBt9yQbYPzccj0hwcOmdPM+eUBaGRWOUYioBqTQ=";
      };
      doCheck = false;
    });

    textual' = textual.overridePythonAttrs (old: rec {
      version = "8.2.1";
      src = fetchFromGitHub {
        owner = "Textualize";
        repo = "textual";
        rev = "v${version}";
        hash = "sha256-GFn+DNpR10G/0qii6wKnh3InbIaDuvriJCCN9M9rsWg=";
      };
      doCheck = false;
      dependencies = (lib.filter (d: d.pname or "" != "platformdirs") (old.dependencies or [ ])) ++ [ platformdirs' ];
    });

    textual-serve' = textual-serve.overridePythonAttrs (old: {
      dependencies = (lib.filter (d: d.pname or "" != "textual") (old.dependencies or [ ])) ++ [ textual' ];
    });

    aiosqlite' = aiosqlite.overridePythonAttrs (old: rec {
      version = "0.22.1";
      src = fetchFromGitHub {
        owner = "omnilib";
        repo = "aiosqlite";
        rev = "v${version}";
        hash = "sha256-voOOFo1OwaRQ3JsDHlBrngP+8ajf0kTNKXJyOaJiTs4=";
      };
      doCheck = false;
    });

    notify-py' = notify-py.overridePythonAttrs (old: rec {
      version = "0.3.43";
      src = fetchFromGitHub {
        owner = "ms7m";
        repo = "notify-py";
        rev = "v${version}";
        hash = "sha256-4PJ/0dLG3bWDuF1G/qUmvNaIUFXgPP2S/0uhZz86WRA=";
      };
      doCheck = false;
    });
  };
in
buildPythonApplication {
  pname = "batrachian-toad";
  version = "0.6.14";
  pyproject = true;

  src = /home/lillecarl/Code/toad;

  build-system = [
    specific.hatchling'
  ];

  dontCheckRuntimeDeps = true;

  dependencies = [
    specific.textual'
    click
    tree-sitter
    httpx
    specific.platformdirs'
    rich
    typeguard
    xdg-base-dirs
    specific.textual-serve'
    textual-speedups
    packaging
    bashlex
    pathspec
    specific.notify-py'
    pyperclip
    watchdog
    setproctitle
    psutil
    specific.aiosqlite'
  ];

  pythonImportsCheck = [ "toad" ];

  meta = with lib; {
    description = "A unified experience for AI in your terminal";
    homepage = "https://github.com/Textualize/toad";
    license = licenses.agpl3Only;
    maintainers = with maintainers; [ ]; # Replace with actual maintainer if known
    mainProgram = "toad";
  };
}
