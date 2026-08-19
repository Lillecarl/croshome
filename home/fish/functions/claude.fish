function claude
    set --export BASH_ENV /etc/profile
    # `command -q` and not `command -v`: -v writes the resolved path to stdout,
    # which inside an `if` still lands on the function's stdout, so every
    # `claude` invocation would print wrapty's store path before running. -q is
    # the same lookup with no output.
    #
    # This also drops a stray `then` -- fish has no `then` keyword, so it was
    # being passed to `command -v` as a second name to look up. That happened
    # to keep working (the builtin succeeds if any name resolves) but it meant
    # the condition was never quite testing what it read as.
    if command -q wrapty
        wrapty claude $argv
    else
        command claude $argv
    end
end
