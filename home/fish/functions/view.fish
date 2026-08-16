function view
    if test -d $argv
        lsd -lah $argv
    else if test -f $argv
        bat $argv
    else
        "idk what to do here bro"
    end
end
