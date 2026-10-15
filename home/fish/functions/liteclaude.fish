function liteclaude --description "claude-code through the local LiteLLM proxy: liteclaude (spark|deepseek) [claude args...]"
    if test (count $argv) -lt 1
        echo "usage: liteclaude (spark|deepseek) [claude args...]" >&2
        return 1
    end
    set -l mode $argv[1]
    set -e argv[1]
    # Declared before the switch: `set -l` inside a case would die with it.
    set -l model ""
    switch $mode
        case spark
            set model muse-spark-1.3-contributor
        case deepseek
            set model deepseek-v4.1-flash
        case '*'
            echo "liteclaude: unknown mode '$mode' (spark|deepseek)" >&2
            return 1
    end
    # The proxy password lives decrypted here (home agenix,
    # secrets/litellm-env.age); it never enters the store or this file.
    set -l envfile "$XDG_RUNTIME_DIR/agenix/litellm-env"
    if not test -f "$envfile"
        echo "liteclaude: $envfile is missing (home agenix has not decrypted?)" >&2
        return 1
    end
    # Docs (docs.litellm.ai/docs/proxy/client_setup/claude_code): the
    # gateway serves the Anthropic Messages API at /v1/messages under the
    # bare base URL. Discovery fills the /model picker from /v1/models.
    # ANTHROPIC_API_KEY must not leak through: claude would send it
    # instead of the gateway key.
    set -lx ANTHROPIC_BASE_URL http://127.0.0.1:4000
    set -lx ANTHROPIC_MODEL $model
    set -lx ANTHROPIC_AUTH_TOKEN (grep '^LITELLM_MASTER_KEY=' "$envfile" | cut -d= -f2)
    set -lx CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY 1
    set -e ANTHROPIC_API_KEY
    # The `claude` function (claude.fish) still applies: wrapty when present.
    claude $argv
end
