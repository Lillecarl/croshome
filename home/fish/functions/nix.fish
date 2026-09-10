function nix
    if test -z "$argv"
        command nix
        return
    end

    # Extract nix subcommand
    set command $argv[1]

    # No NIX_CONFIG here: an export leaks into every shell and agent spawned
    # later, and the token it carried is long gone. `env NIX_CONFIG=...`
    # in front of the command if one is ever needed again.
    if test $command = build
        command nix build --no-link --print-out-paths --impure $argv[2..-1]
    else if test $command = run
        command nix run --impure $argv[2..-1]
    else
        command nix $argv
    end
end
