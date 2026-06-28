function show
    if test -f $argv[1]
        bat $argv
    else if test -d $argv[1]
        lsd -lah $argv
    end
end
