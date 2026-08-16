function copy --description 'Copy arguments to the system clipboard'
    # This file is shared verbatim by every host, so the choice is made at call
    # time rather than by the Nix evaluation: wl-copy talks to a Wayland
    # compositor, and macOS has pbcopy instead.
    if command --query pbcopy
        echo $argv | pbcopy
    else
        echo $argv | wl-copy -n
    end
end
