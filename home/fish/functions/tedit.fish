function tedit
    set file (mktemp)
    tmux capture-pane -pJ -S -1000 | grep "\S" >$file
    hx $file +99999
    rm $file
end
