function nixb --wraps=nix
    nix --builders "eu.nixbuild.net aarch64-linux" --extra-substituters "ssh://eu.nixbuild.net?trusted=true" $argv
end
