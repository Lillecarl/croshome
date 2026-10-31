function dclaude --description "shared ~/.claude, work login from the token in ~/.claude/oauth-dynamist" --wraps claude
    # Shared-everything variant of dclaude: sessions, history and settings
    # stay in ~/.claude, only the login differs. Claude Code takes a login
    # from CLAUDE_CODE_OAUTH_TOKEN before its credentials file, so no file is
    # remapped.
    #
    # Not bwrap: an unprivileged bind mount needs a user namespace, which maps
    # only this uid, so every root-owned file reads as nobody's -- ssh then
    # refuses ~/.ssh/config (a store path) and no push works -- and bwrap sets
    # no_new_privs, so sudo and ai-rebuild cannot elevate.
    #
    # The token is long-lived: `claude setup-token`, logged in to the work
    # account, prints it. The accessToken in .credentials.json is not one; it
    # expires within hours.
    set -l token_file ~/.claude/oauth-dynamist
    if not test -s $token_file
        echo "dclaude2: $token_file is missing; run `claude setup-token` with the work login and save what it prints there" >&2
        return 1
    end
    # Undo a prior dclaude in this shell; default backend is ~/.claude anyway.
    set --export CLAUDE_CONFIG_DIR ~/.claude
    CLAUDE_CODE_OAUTH_TOKEN=(string trim < $token_file) claude $argv
end
