function unscroll --description "Unscroll lines from terminal scrollback (Kitty extension)"
    echo asdf
    set -l lines 3
    if test -n "$argv[1]"
        set lines $argv[1]
    end
    printf '\e[%s+T' $lines
    printf '\e[%sB' $lines
end
