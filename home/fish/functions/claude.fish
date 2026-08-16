function claude
    set --export BASH_ENV /etc/profile
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000
    export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=95
    command claude $argv
end
