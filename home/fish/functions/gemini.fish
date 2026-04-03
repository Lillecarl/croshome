function gemini
    set --export --function PAGER cat
    set --export --function EDITOR cat
    set --export --function GEMINI_DEBUG_LOG_FILE ~/.local/share/gemini/gemini.log
    command gemini $argv
end
