function nix
    if test -z "$argv"
        command nix
        return
    end

    # Extract nix subcommand
    set command $argv[1]

    set --export NIX_CONFIG "access-tokens = github.com=$(echo $PS_GHBASIC | base64 -d)"

    if test $command = build
        command nix build --no-link --print-out-paths --impure $argv[2..-1]
    else if test $command = run
        command nix run --impure $argv[2..-1]
    else
        command nix $argv
    end
end
