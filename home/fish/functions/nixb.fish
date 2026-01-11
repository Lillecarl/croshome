function nixb --wraps=nix
    nix $argv --builders "eu.nixbuild.net aarch64-linux" --extra-substituters "ssh://eu.nixbuild.net?trusted=true"
end
