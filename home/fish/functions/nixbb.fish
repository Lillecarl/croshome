function nixbb --wraps=nix
    nix --builders "eu.nixbuild.net aarch64-linux; eu.nixbuild.net x86_64-linux" --extra-substituters "ssh://eu.nixbuild.net?trusted=true" $argv
end
