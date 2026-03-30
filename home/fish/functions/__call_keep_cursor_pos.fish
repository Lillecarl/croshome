function __call_keep_cursor_pos
    # Check if we are in a tmux session
    if test -n "$TMUX"
        set pre_height (tmux display-message -p '#{cursor_y}')
    end

    _atuin_search

    if test -n "$TMUX"
        set post_height (tmux display-message -p '#{cursor_y}')
        set drop (math $pre_height - $post_height)
    end


    if test -n "$TMUX" && test $drop -gt 0
        # This scrolls the commandline to the bottom after an atuin search
        echo -en '\e['$drop'+T'
        echo -en '\e['$drop'B'
    end

    commandline -f repaint
end
